-module(merge_index_tests).
-compile(export_all).
-import(common, [g_i/0, g_f/0, g_t/0, g_props/0, g_value/0]).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("common.hrl").

-record(state, {server_pid,
                postings=[]}).

prop_api_test_() ->
    {timeout, 60,
     fun() ->
            ?assert(eqc:quickcheck(eqc:numtests(200,?QC_OUT(prop_api()))))
     end
    }.

prop_api() ->
    application:load(merge_index),
    ok = application:start(sasl),
    %% Comment out following lines to see error reports...otherwise
    %% it's too much noise
    error_logger:delete_report_handler(sasl_report_tty_h),
    error_logger:delete_report_handler(error_logger_tty_h),

    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(
               begin
                   application:stop(merge_index),
                   ok = application:start(merge_index),

                   {H, S, Res} = run_commands(?MODULE, Cmds),

                   Pid = S#state.server_pid,
                   if Pid /= undefined -> merge_index:stop(Pid);
                      true -> ok
                   end,

                   case Res of
                       ok -> ok;
                       _ -> io:format(user,
                                      "QC Commands: ~p~n"
                                      "QC History: ~p~n"
                                      "QC State: ~p~n"
                                      "QC result: ~p~n",
                                      [Cmds, H, S, Res])
                   end,

                   aggregate(command_names(Cmds), Res == ok)
               end)).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================

initial_state() ->
    #state{}.

command(#state{server_pid=undefined}) ->
    {call,?MODULE,init,[g_settings()]};
command(S) ->
    P = S#state.server_pid,
    Postings = S#state.postings,
    oneof([{call,?MODULE,index, [P, g_postings()]},
           {call,?MODULE,is_empty, [P]},
           {call,?MODULE,info, [P, g_posting(Postings)]},
           {call,?MODULE,fold, [P, fun fold_fun/7, []]},
           {call,?MODULE,stream, [P, g_posting(Postings)]},
           %% TODO don't hardcode size to 'all'
           {call,?MODULE,range, [P, g_range_query(Postings), all]},
           {call,?MODULE,drop, [P]},
           {call,?MODULE,compact, [P]}]).

next_state(S, Pid, {call,_,init,_}) ->
    S#state{server_pid=Pid};
next_state(S, _Res, {call,_,index,[_,Postings]}) ->
    case Postings of
        [] -> S;
        _ ->
            Postings0 = S#state.postings,
            S#state{postings=Postings0++Postings}
    end;
next_state(S, _Res, {call,_,drop,_}) ->
    S#state{postings=[]};
next_state(S, _Res, {call,_,_,_}) -> S.

precondition(_,_) ->
    true.

postcondition(S, {call,_,is_empty,_}, V) ->
    case S#state.postings of
        [] -> ok == ?assertEqual(true, V);
        _ -> ok == ?assertEqual(false, V)
    end;
postcondition(_, {call,_,index,_}, V) ->
    ok == ?assertEqual(ok, V);
postcondition(#state{postings=Postings}, {call,_,info,[_,I,F,T]}, V) ->
    L = [x || {Ii, Ff, Tt} <- Postings,
              (I == Ii) andalso (F == Ff) andalso (T == Tt)],
    {ok, [{T, W}]} = V,
    ok == ?assertEqual(length(L), W);
postcondition(#state{postings=Postings}, {call,_,fold,_}, {ok, V}) ->
    %% NOTE: The order in which fold returns postings is not
    %% deterministic thus both must be sorted.
    ok == ?assertEqual(lists:sort(Postings), lists:sort(V));
postcondition(#state{postings=Postings},
              {call,_,stream,[_,{I,F,T,_,_,_}]}, V) ->
    %% TODO This is actually testing the wrong property b/c there is
    %% currently a bug in the range call that causes Props vals to be
    %% lost -- https://issues.basho.com/show_bug.cgi?id=1099
    L1 = lists:sort([{Ii,Ff,Tt,Vv,-1*TS,P} || {Ii,Ff,Tt,Vv,P,TS} <- Postings]),
    L2 = [{Vv,ignore} || {Ii,Ff,Tt,Vv,_,_} <- L1,
                   (I == Ii) andalso (F == Ff) andalso (T == Tt)],
    L3 = lists:foldl(fun unique_vals/2, [], lists:sort(L2)),
    V2 = [{Val,ignore} || {Val,_} <- lists:sort(V)],
    ok == ?assertEqual(L3, V2);
postcondition(#state{postings=Postings},
              {call,_,range,[_,{I,F,ST,ET},all]}, V) ->
    L1 = lists:sort([{Ii,Ff,Tt,Vv,-1*TS,P} || {Ii,Ff,Tt,Vv,P,TS} <- Postings]),
    L2 = [{Vv,ignore} || {Ii,Ff,Tt,Vv,_,_} <- L1,
                   (I == Ii) andalso (F == Ff)
                       andalso (ST =< Tt) andalso (ET >= Tt)],
    %% TODO This is actually testing the wrong property b/c there is
    %% currently a bug in the range call that causes Props vals to be
    %% lost -- https://issues.basho.com/show_bug.cgi?id=1099 --
    %% uncomment the following line when it's fixed

    %% L3 = lists:sort((ordsets:from_list(L2)),
    L3 = lists:foldl(fun unique_vals/2, [], lists:sort(L2)),
    V2 = [{Val,ignore} || {Val,_} <- lists:sort(V)],
    ok == ?assertEqual(L3, V2);
postcondition(#state{postings=[]}, {call,_,drop,_}, V) ->
    ok == ?assertEqual(ok, V);
postcondition(_, {call,_,compact,[_]}, V) ->
    {Msg, _SegsCompacted, _BytesCompacted} = V,
    ok == ?assertEqual(ok, Msg);
postcondition(_,_,_) -> true.

%% ====================================================================
%% generators
%% ====================================================================

g_size() ->
    choose(64, 1024).

g_ms() ->
    choose(100, 5000).

g_settings() ->
    [g_size(), g_size(), g_ms(), choose(1,20), g_size(), g_size(),
     g_size(), g_ms(), g_size(), g_size(), choose(1,20), choose(0,20),
     choose(0,9)].

g_pos_tstamp() ->
    choose(0, ?POW_2(31)).

g_posting() ->
    {g_i(), g_f(), g_t(), g_value(), g_props(), g_pos_tstamp()}.

g_postings() ->
    I = <<"index">>,
    F = <<"field">>,
    list(frequency([{10, {I,F,g_t(),g_value(),g_props(),g_pos_tstamp()}},
                    {1, g_posting()}])).

g_posting(Postings) ->
    case length(Postings) of
        0 ->
            g_posting();
        _ ->
            oneof([elements(Postings),
                   g_posting()])
    end.

g_range_query(Postings) ->
    case length(Postings) of
        0 ->
            {g_i(), g_f(), g_t(), g_t()};
        Len ->
            {I,F,ST,_,_,_} = lists:nth(random:uniform(Len), Postings),
            {I, F, ST, g_t()}
    end.

%% ====================================================================
%% wrappers
%% ====================================================================

init([BRS,BDWS,BDWM,MCS,SQRAS,SCRAS,SFBSandSDWS,SDWM,SFRS,SBS,
      SVSS,SVCT,SVCL]) ->
    Root = "/tmp/test/prop_api",
    os:cmd(?FMT("rm -rf ~s; mkdir -p ~s", [Root, Root])),
    set(buffer_rollover_size, BRS),
    set(buffer_delayed_write_size, BDWS),
    set(buffer_delayed_write_ms, BDWM),
    set(max_compact_segments, MCS),
    set(segment_query_read_ahead_size, SQRAS),
    set(segment_compact_read_ahead_size, SCRAS),
    set(segment_file_buffer_size, SFBSandSDWS),
    set(segment_delayed_write_size, SFBSandSDWS),
    set(segment_delayed_write_ms, SDWM),
    set(segment_full_read_size, SFRS),
    set(segment_block_size, SBS),
    set(segment_values_staging_size, SVSS),
    set(segment_values_compression_threshold, SVCT),
    set(segment_values_compression_level, SVCL),

    merge_index:start_link(Root),
    {ok, Pid} = merge_index:start_link(Root),
    Pid.

index(Pid, Postings) ->
    merge_index:index(Pid, Postings).

info(Pid, {I,F,T,_,_,_}) ->
    merge_index:info(Pid, I, F, T).

is_empty(Pid) ->
    merge_index:is_empty(Pid).

fold(Pid, Fun, Acc) ->
    merge_index:fold(Pid, Fun, Acc).

stream(Pid, {I,F,T,_,_,_}) ->
    Ref = make_ref(),
    Sink = spawn(?MODULE, data_sink, [Ref, [], false]),
    Ft = fun(_,_) -> true end,
    ok = merge_index:stream(Pid, I, F, T, Sink, Ref, Ft),
    wait_for_it(Sink, Ref).

range(Pid, {I, F, ST, ET}, Size) ->
    Ref = make_ref(),
    Sink = spawn(?MODULE, data_sink, [Ref, [], false]),
    Ft = fun(_,_) -> true end,
    ok = merge_index:range(Pid, I, F, ST, ET, Size, Sink, Ref, Ft),
    wait_for_it(Sink, Ref).

drop(Pid) ->
    merge_index:drop(Pid).

compact(Pid) ->
    merge_index:compact(Pid).

%% ====================================================================
%% helpers
%% ====================================================================

set(Par, Val) ->
    application:set_env(merge_index, Par, Val).

fold_fun(I, F, T, V, P, TS, Acc) ->
    [{I, F, T, V, P, TS}|Acc].

unique_vals({V,P}, Acc) ->
    case orddict:find(V, Acc) of
        {ok, _} ->
            Acc;
        error ->
            orddict:store(V, P, Acc)
    end.

data_sink(Ref, Acc, Done) ->
    receive
        {result_vec, Data, Ref} ->
            data_sink(Ref, Acc++Data, false);
        {result, '$end_of_table', Ref} ->
            data_sink(Ref, Acc, true);
        {gimmie, From, Ref} ->
            From ! {ok, Ref, lists:reverse(Acc)};
        {'done?', From, Ref} ->
            From ! {ok, Ref, Done},
            data_sink(Ref, Acc, Done);
        Other ->
            ?debugFmt("Unexpected msg: ~p~n", [Other]),
            data_sink(Ref, Acc, Done)
    end.

wait_for_it(Sink, Ref) ->
    S = self(),
    Sink ! {'done?', S, Ref},
    receive
        {ok, Ref, true} ->
            Sink ! {gimmie, S, Ref},
            receive
                {ok, Ref, Data} ->
                    Data;
                {ok, ORef, _} ->
                    ?debugFmt("Received data for older run: ~p~n", [ORef])
            end;
        {ok, Ref, false} ->
            timer:sleep(100),
            wait_for_it(Sink, Ref);
        {ok, ORef, _} ->
            ?debugFmt("Received data for older run: ~p~n", [ORef])
    end.
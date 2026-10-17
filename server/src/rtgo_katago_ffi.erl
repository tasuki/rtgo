%% One port owns one persistent engine, shared by all rooms. Never run inference
%% in a game/lobby actor. KataGo's stdout is JSON; stderr stays on server stderr.
-module(rtgo_katago_ffi).
-behaviour(gen_server).
-export([start/0, available/0, analyse/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(ENGINE, "/opt/katago/katago").
-define(MODEL, "/opt/katago/kata1-b6c96-s175395328-d26788732.txt.gz").

available() -> filelib:is_regular(?ENGINE) andalso filelib:is_regular(?MODEL).

start() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, _} -> {ok, nil};
        {error, {already_started, _}} -> {ok, nil};
        _ -> {error, nil}
    end.

analyse(Query) ->
    try
        {ok, nil} = start(),
        gen_server:call(?MODULE, {analyse, Query}, 20000)
    catch _:_ -> {error, nil}
    end.

init([]) ->
    process_flag(trap_exit, true),
    Port = open_port({spawn_executable, ?ENGINE}, [
        binary, use_stdio, exit_status, {line, 1048576},
        {args, ["analysis", "-config", "/opt/katago/analysis.cfg",
                "-model", ?MODEL, "-quit-without-waiting"]}
    ]),
    {ok, #{port => Port, pending => #{}, buffer => <<>>}}.

handle_call({analyse, Query}, From, #{port := Port, pending := Pending} = State) ->
    #{<<"id">> := Id} = json:decode(Query),
    true = port_command(Port, [Query, <<"\n">>]),
    Timer = erlang:send_after(15000, self(), {timeout, Id}),
    {noreply, State#{pending := Pending#{Id => {From, Timer}}}};
handle_call(_, _, State) -> {reply, {error, nil}, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info({Port, {data, {noeol, Chunk}}}, #{port := Port, buffer := Buffer} = State) ->
    {noreply, State#{buffer := <<Buffer/binary, Chunk/binary>>}};
handle_info({Port, {data, {eol, Chunk}}}, #{port := Port, buffer := Buffer} = State) ->
    Line = <<Buffer/binary, Chunk/binary>>,
    handle_line(Line, State#{buffer := <<>>});
handle_info({timeout, Id}, #{pending := Pending} = State) ->
    case maps:is_key(Id, Pending) of
        true -> {stop, engine_timeout, State};
        false -> {noreply, State}
    end;
handle_info({Port, {exit_status, _}}, #{port := Port} = State) ->
    {stop, engine_exited, State};
handle_info({'EXIT', Port, _}, #{port := Port} = State) ->
    {stop, engine_exited, State};
handle_info(_, State) -> {noreply, State}.

handle_line(Line, #{pending := Pending} = State) ->
    try json:decode(Line) of
        #{<<"warning">> := Warning} ->
            logger:warning("KataGo: ~ts", [Warning]),
            {noreply, State};
        #{<<"id">> := Id} = Response ->
            case maps:take(Id, Pending) of
                {{From, Timer}, Rest} ->
                    erlang:cancel_timer(Timer),
                    Reply = case maps:is_key(<<"error">>, Response) of
                        true ->
                            logger:warning("KataGo: ~ts", [Line]),
                            {error, nil};
                        false -> {ok, Line}
                    end,
                    gen_server:reply(From, Reply),
                    {noreply, State#{pending := Rest}};
                error -> {noreply, State}
            end;
        _ -> {noreply, State}
    catch _:_ ->
        logger:warning("Invalid KataGo output: ~ts", [Line]),
        {noreply, State}
    end.

terminate(_, #{port := Port, pending := Pending}) ->
    maps:foreach(fun(_, {From, Timer}) ->
        erlang:cancel_timer(Timer),
        gen_server:reply(From, {error, nil})
    end, Pending),
    catch port_close(Port),
    ok.

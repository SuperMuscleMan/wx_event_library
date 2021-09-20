%%%-------------------------------------------------------------------
%%% @author WeiMengHuan
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 21. 三月 2021 15:01
%%%-------------------------------------------------------------------
-module(wx_event_server).
%%%=======================STATEMENT====================
-description("wx_event_server").
-copyright('').
-author("wmh, SuperMuscleMan@outlook.com").
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([set/1, throw_event/3]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("wx_log_library/include/wx_log.hrl").

-define(SERVER, ?MODULE).
-define(Timer_Seconds, 1000).%% 事件定时器精度为1s
-define(Hibernate_TimeOut, 10000).

-record(state, {run_list = []}).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
	{ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
set({{_, Event}, {M, F, A, TimeOut}}) ->
	gen_server:call(?MODULE, {set, Event, M, F, A, TimeOut}).

%% -----------------------------------------------------------------
%% Func:
%% Description:处理事件
%% Returns:
%% -----------------------------------------------------------------
throw_event(Src, Event, Args) ->
	try
		case get_data({Src, Event}) of
			{_, List} ->
				[handle_event(Src, Event, M, F, A, TimeOut, Args) ||
					{M, F, A, TimeOut} <- List];
			_ ->
				erlang:error({no_event_key, {key, Event}})
		end
	catch
		_E1:E2:E3 ->
			?ERR({event_err, {reason, E2}, {key, Event}, {args, Args}, E3})
	end.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
	{ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term()} | ignore).
init([]) ->
	erlang:process_flag(trap_exit, true),
	ets:new(?MODULE, [named_table, {keypos, 1}, {read_concurrency, true}]),
	{ok, #state{}, ?Hibernate_TimeOut}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
		State :: #state{}) ->
	{reply, Reply :: term(), NewState :: #state{}} |
	{reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
	{noreply, NewState :: #state{}} |
	{noreply, NewState :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
	{stop, Reason :: term(), NewState :: #state{}}).
handle_call({set, Key, M, F, A, TimeOut}, _From, State) ->
	case get_data(Key) of
		{_, List} ->
			ets:insert(?MODULE, {Key, [{M, F, A, TimeOut} | List]});
		_ ->
			ets:insert(?MODULE, {Key, [{M, F, A, TimeOut}]})
	end,
	{reply, ok, State, ?Hibernate_TimeOut};
handle_call(_Request, _From, State) ->
	{reply, ok, State, ?Hibernate_TimeOut}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
	{noreply, NewState :: #state{}} |
	{noreply, NewState :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: #state{}}).
handle_cast({run, Pid, Src, Event, M, F, Args, Expire}, #state{run_list = RunList} = State) ->
	if RunList =:= [] ->
		send_timer();
		true ->
			ok
	end,
	{noreply, State#state{run_list = [{Pid, Src, Event, M, F, Args, Expire} | RunList]}, ?Hibernate_TimeOut};
handle_cast(_, State) ->
	{noreply, State, ?Hibernate_TimeOut}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
	{noreply, NewState :: #state{}} |
	{noreply, NewState :: #state{}, timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: #state{}}).
handle_info(check_expire, #state{run_list = RunList} = State) ->
	RunList2 =
		case check_expire(RunList, wx_time:now_millisec(), []) of
			[] ->
				[];
			RunList1 ->
				send_timer(),
				RunList1
		end,
	{noreply, State#state{run_list = RunList2}, ?Hibernate_TimeOut};
handle_info(timeout, State) ->
	{noreply, State, hibernate};
handle_info(_, State) ->
	{noreply, State, ?Hibernate_TimeOut}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
		State :: #state{}) -> term()).
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
		Extra :: term()) ->
	{ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_data(Key) ->
	case ets:lookup(?MODULE, Key) of
		[D] -> D;
		_ ->
			none
	end.

%% 检测过期
check_expire([{Pid, Src, Event, M, F, Args, Expire} = H | T], Now, Result)->
	case is_process_alive(Pid) of
		false ->
			check_expire(T, Now, Result);
		true  when Now > Expire ->
			CurStack = process_info(Pid, current_stacktrace),
			erlang:exit(Pid, event_expire),
			?ERR({event_expire, {src, Src}, {event, Event}, {current_stack, CurStack},
				{m, M}, {f, F}, {args, Args}}),
			check_expire(T, Now, Result);
		true ->
			check_expire(T, Now, [ H| Result])
	end;
%%check_expire([H | T], Now, R) ->
%%	check_expire(T, Now, [H | R]);
check_expire([], _, R) ->
	R.

%% TimeOut 大于0是异步事件
handle_event(Src, Event, M, F, A, TimeOut, Args) when TimeOut > 0 ->
	erlang:spawn_monitor(
		fun() ->
			%% 当事件进程堆栈大小超过10MB时kill掉10*1024*1024
			erlang:process_flag(max_heap_size, #{size => 16#140000, kill => true,
				error_logger => true}),
			Now = wx_time:now_millisec(),
			gen_server:cast(?MODULE, {run, self(), Src, Event, M, F, Args, TimeOut + Now}),
			handle_(Src, Event, M, F, A, TimeOut, Args)
		end);
handle_event(Src, Event, M, F, A, TimeOut, Args) ->
	handle_(Src, Event, M, F, A, TimeOut, Args).
handle_(Src, Event, M, F, A, TimeOut, Args) ->
	try
		?DEBUG({Src, Event, {M, F, A, TimeOut, Args}}),
		M:F(A, Src, Event, Args)
	catch
		_E1:E2:E3 ->
			?ERR({handle_event_err, {reason, E2}, {src, Src}, {event, Event}, {m, M},
				{f, F}, {a, A}, {timeout, TimeOut}, {args, Args}, E3})
	end.

send_timer() ->
	erlang:send_after(?Timer_Seconds, ?MODULE, check_expire).
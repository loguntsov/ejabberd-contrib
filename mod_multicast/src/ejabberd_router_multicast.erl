%%%----------------------------------------------------------------------
%%% File    : ejabberd_router_multicast.erl
%%% Author  : Badlop <badlop@ono.com>
%%% Purpose : Multicast router
%%% Created : 11 Aug 2007 by Badlop <badlop@ono.com>
%%%----------------------------------------------------------------------

-module(ejabberd_router_multicast).
-author('alexey@sevcom.net').
-author('badlop@ono.com').

-behaviour(gen_server).

%% API
-export([route_multicast/4,
	 register_route/1,
	 unregister_route/1
	]).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-record(route_multicast, {domain, pid}).
-record(state, {}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


route_multicast(From, Domain, Destinations, Packet) ->
    case catch do_route(From, Domain, Destinations, Packet) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p~nwhen processing: ~p",
		       [Reason, {From, Domain, Destinations, Packet}]);
	_ ->
	    ok
    end.

register_route(Domain) ->
    case jlib:nameprep(Domain) of
	error ->
	    erlang:error({invalid_domain, Domain});
	LDomain ->
	    Pid = self(),
	    F = fun() ->
			mnesia:write(#route_multicast{domain = LDomain,
						      pid = Pid})
		end,
	    mnesia:transaction(F)
    end.

unregister_route(Domain) ->
    case jlib:nameprep(Domain) of
	error ->
	    erlang:error({invalid_domain, Domain});
	LDomain ->
	    Pid = self(),
	    F = fun() ->
		    case mnesia:select(route_multicast,
		       [{#route_multicast{pid = Pid, domain = LDomain, _ = '_'},
			 [],
			 ['$_']}]) of
			    [R] -> mnesia:delete_object(R);
			    _ -> ok
		    end
		end,
	    mnesia:transaction(F)
    end.


%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    mnesia:create_table(route_multicast,
			[{ram_copies, [node()]},
			 {type, bag},
			 {attributes,
			  record_info(fields, route_multicast)}]),
    mnesia:add_table_copy(route_multicast, node(), ram_copies),
    mnesia:subscribe({table, route_multicast, simple}),
    lists:foreach(
      fun(Pid) ->
	      erlang:monitor(process, Pid)
      end,
      mnesia:dirty_select(route_multicast, [{{route_multicast, '_', '$1'}, [], ['$1']}])),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route_multicast, From, Domain, Destinations, Packet}, State) ->
    case catch do_route(From, Domain, Destinations, Packet) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p~nwhen processing: ~p",
		       [Reason, {From, Domain, Destinations, Packet}]);
	_ ->
	    ok
    end,
    {noreply, State};
handle_info({mnesia_table_event, {write, #route_multicast{pid = Pid}, _ActivityId}},
	    State) ->
    erlang:monitor(process, Pid),
    {noreply, State};
handle_info({'DOWN', _Ref, _Type, Pid, _Info}, State) ->
    F = fun() ->
		Es = mnesia:select(
		       route_multicast,
		       [{#route_multicast{pid = Pid, _ = '_'},
			 [],
			 ['$_']}]),
		lists:foreach(
		  fun(E) ->
			  mnesia:delete_object(E)
		  end, Es)
	end,
    mnesia:transaction(F),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
%% From = #jid
%% Destinations = [#jid]
do_route(From, Domain, Destinations, Packet) ->

    ?DEBUG("route_multicast~n\tfrom ~s~n\tdomain ~s~n\tdestinations ~p~n\tpacket ~p~n",
	   [jlib:jid_to_string(From),
	    Domain,
	    [jlib:jid_to_string(To) || To <- Destinations],
	    Packet]),

    {Groups, Rest} = lists:foldr(
                       fun(Dest, {Groups1, Rest1}) ->
                               case ejabberd_sm:get_session_pid(Dest#jid.luser, Dest#jid.lserver, Dest#jid.lresource) of
                                   none ->
                                       {Groups1, [Dest|Rest1]};
                                   Pid ->
                                       Node = node(Pid),
                                       if Node /= node() ->
                                               {dict:append(Node, Dest, Groups1), Rest1};
                                          true ->
                                               {Groups1, [Dest|Rest1]}
                                       end
                               end
                       end, {dict:new(), []}, Destinations),

    dict:map(
      fun(Node, [Single]) ->
              ejabberd_cluster:send({ejabberd_sm, Node},
                                    {route, From, Single, Packet});
         (Node, Dests) ->
              ejabberd_cluster:send({ejabberd_sm, Node},
                                    {route_multiple, From, Dests, Packet})
      end, Groups),

    %% Try to find an appropriate multicast service
    case mnesia:dirty_read(route_multicast, Domain) of

	%% If no multicast service is available in this server, send manually
	[] -> do_route_normal(From, Rest, Packet);

	%% If available, send the packet using multicast service
	[R] ->
	    case R#route_multicast.pid of
		Pid when is_pid(Pid) ->
		    Pid ! {route_trusted, From, Rest, Packet};
		_ -> do_route_normal(From, Rest, Packet)
	    end
    end.

do_route_normal(From, Destinations, Packet) ->
    [ejabberd_router:route(From, To, Packet) || To <- Destinations].

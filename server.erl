-module(server).

-export([start_server/0]).

-include_lib("./defs.hrl").

-spec start_server() -> _.
-spec loop(_State) -> _.
-spec do_join(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_leave(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_new_nick(_State, _Ref, _ClientPID, _NewNick) -> _.
-spec do_client_quit(_State, _Ref, _ClientPID) -> _NewState.

start_server() ->
    catch(unregister(server)),
    register(server, self()),
    case whereis(testsuite) of
	undefined -> ok;
	TestSuitePID -> TestSuitePID!{server_up, self()}
    end,
    loop(
      #serv_st{
	 nicks = maps:new(), %% nickname map. client_pid => "nickname"
	 registrations = maps:new(), %% registration map. "chat_name" => [client_pids]
	 chatrooms = maps:new() %% chatroom map. "chat_name" => chat_pid
	}
     ).

loop(State) ->
    receive 
	%% initial connection
	{ClientPID, connect, ClientNick} ->
	    NewState =
		#serv_st{
		   nicks = maps:put(ClientPID, ClientNick, State#serv_st.nicks),
		   registrations = State#serv_st.registrations,
		   chatrooms = State#serv_st.chatrooms
		  },
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, join, ChatName} ->
	    NewState = do_join(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, leave, ChatName} ->
	    NewState = do_leave(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to register a new nickname
	{ClientPID, Ref, nick, NewNick} ->
	    NewState = do_new_nick(State, Ref, ClientPID, NewNick),
	    loop(NewState);
	%% client requests to quit
	{ClientPID, Ref, quit} ->
	    NewState = do_client_quit(State, Ref, ClientPID),
	    loop(NewState);
	{TEST_PID, get_state} ->
	    TEST_PID!{get_state, State},
	    loop(State)
    end.

%% executes join protocol from server perspective
do_join(ChatName, ClientPID, Ref, State) ->
	case maps:is_key(ChatName, State#serv_st.chatrooms) of
		false -> 
			ChatPID = spawn(chatroom, start_chatroom, [ChatName]),
			{ok, ClientNick} = maps:find(ClientPID, State#serv_st.nicks),
			ChatPID!{self(), Ref, register, ClientPID, ClientNick},
			#serv_st{
				nicks = State#serv_st.nicks,
				registrations = maps:put(ChatName,[ClientPID],State#serv_st.registrations),
				chatrooms = maps:put(ChatName, ChatPID,State#serv_st.chatrooms)
			};
		true ->
			{ok, ChatPID} = maps:find(ChatName, State#serv_st.chatrooms),
			{ok, ClientNick} = maps:find(ClientPID, State#serv_st.nicks),
			ChatPID!{self(), Ref, register, ClientPID, ClientNick},
			PIDs = maps:get(ChatName, State#serv_st.registrations),
			#serv_st{
				nicks = State#serv_st.nicks,
				registrations = maps:put(ChatName,[ClientPID]++PIDs,State#serv_st.registrations),
				chatrooms = State#serv_st.chatrooms
			}
	end.

%% executes leave protocol from server perspective
do_leave(ChatName, ClientPID, Ref, State) ->
	ChatPID = maps:get(ChatName, State#serv_st.chatrooms),
	PIDs = maps:get(ChatName, State#serv_st.registrations),
	ChatPID!{self(), Ref, unregister, ClientPID},
	ClientPID!{self(), Ref, ack_leave},
	#serv_st{
		nicks = State#serv_st.nicks,
		registrations = maps:put(ChatName,PIDs--[ClientPID],State#serv_st.registrations),
		chatrooms = State#serv_st.chatrooms
	}.

%% executes new nickname protocol from server perspective
%% The server must now update all chatrooms to which the client belongs 
%% that the nickname of the
%% user has changed, by sending each relevant chatroom the message 
%% {self(), Ref, update nick,

nick_helper(State,Ref, ClientPID, NewNick,Matches)->
	case Matches of
		[H|T] -> 
			ChatPID = maps:get(H, State#serv_st.chatrooms),
			ChatPID!{self(), Ref, update_nick, ClientPID, NewNick},
			nick_helper(State,Ref, ClientPID, NewNick,T);
		[] ->
			[]
	end.

do_new_nick(State, Ref, ClientPID, NewNick) ->
	AllNicks = maps:values(State#serv_st.nicks),
	case lists:member(NewNick, AllNicks) of 
		true ->
			ClientPID!{self(),Ref,err_nick_used}, 
			State;
		false ->
			AllChatRoomNames = maps:keys(State#serv_st.registrations),
			Matches = lists:filter(fun(X) -> lists:member(ClientPID, maps:get(X,State#serv_st.registrations)) end,AllChatRoomNames),
			nick_helper(State,Ref, ClientPID,NewNick,Matches),
			ClientPID!{self(),Ref,ok_nick},
			#serv_st{
				nicks = maps:update(ClientPID, NewNick, State#serv_st.nicks),
				registrations = State#serv_st.registrations,
			 	chatrooms = State#serv_st.chatrooms
			}
	end.
quick_helper(State,Ref, ClientPID,Matches)->
	case Matches of
		[H|T] -> 
			ChatPID = maps:get(H, State#serv_st.chatrooms),
			ChatPID!{self(), Ref, unregister, ClientPID},
			quick_helper(State,Ref, ClientPID,T);
		[] ->
			[]
	end.

update_registrations(ClientPID, Regs)->
	case Regs of
		[{X,Y}|T] ->
			[{X,lists:delete(ClientPID, Y)}] ++ update_registrations(ClientPID, T);
		[] ->
			[]
	end.

%% executes client quit protocol from server perspective
%%Tell each chatroom to which the client is registered that the client is leaving. To do so, send
%% the message {self(), Ref, unregister, ClientPID} [C] to each chatroom in which
%% the client is registered. Note that this is the same message as when a client asks to leave a
%% chatroom, so this should be handled already
do_client_quit(State, Ref, ClientPID) ->
	UpdatedNicks = maps:remove(ClientPID, State#serv_st.nicks),
	AllChatRoomNames = maps:keys(State#serv_st.registrations),
	Matches = lists:filter(fun(X) -> lists:member(ClientPID, maps:get(X,State#serv_st.registrations)) end,AllChatRoomNames),
	quick_helper(State,Ref, ClientPID,Matches),
	UpdatedRegistrations = maps:from_list(update_registrations(ClientPID,maps:to_list(State#serv_st.registrations))),
	ClientPID!{self(), Ref, ack_quit},
	#serv_st{
		nicks = UpdatedNicks,
		registrations = UpdatedRegistrations,
		chatrooms = State#serv_st.chatrooms
	}.



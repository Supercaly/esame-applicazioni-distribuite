-module(db).

-behaviour(gen_server).

-export([
    start_link/0,
    stop_link/0
]).

% gen_server callbaks.
-export([
    code_change/3,
    init/1, 
    handle_call/3, 
    handle_cast/2, 
    handle_info/2, 
    terminate/2
]).

% Start an instance of db.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop_link() ->
    gen_server:call(?MODULE, stop).

%%%%%%%%%%%%%%%%%%%%%%
% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%

% init/1 callback from gen_server.
init(_Args) ->
    process_flag(trap_exit, true),
    % Start mnesia with the default schema;
    % the schema is manipulated with messages.
    case ensure_started() of
        ok -> {ok, []};
        {error, Reason} -> {stop, Reason}
    end.

% handle_call/3 callback from gen_server.
% Receives messages:
%   create_space          |
%   {add_to_space, Nodes} |
%   remove_from_space     |
%   stop                  |
%
% Responds with:
%   ok | {error, Reason
handle_call(create_space, _From, _State) ->
    % Create a new tuple space
    Res = try do_create_new_space()
    catch
        error:{badmatch, Error} -> 
            revert_db(),
            Error
    end,
    {reply, Res, _State};
handle_call({add_to_space, OtherNode}, _From, _State) when is_atom(OtherNode) ->
    % Add this node to given space
    Res = try do_add_node(OtherNode)
    catch
        error:{badmatch, Error} -> 
            revert_db(),
            Error
    end,
    {reply, Res, _State};
handle_call(remove_from_space, _From, _State) ->
    % Remove this node from the space he's in
    Res = try do_remove_node()
    catch
        error:{badmatch, Error} -> 
            revert_db(),
            Error
    end,
    {reply, Res, _State};
handle_call(list_nodes, _From, _State) ->
    % List all nodes in the space
    Nodes = list_connected_nodes(),
    {reply, {ok, Nodes}, _State};
handle_call(stop, _From, _State) ->
    % TODO: Remove stop call
    % TODO: Determine what happens when db is terminated
    {stop, normal, stopped, _State};
handle_call(_Request, _From, _State) ->
    {reply, {error, bad_request}, _State}.

% handle_cast/2 callback from gen_server.
handle_cast(_Msg, _State) ->
    {noreply, _State}.

% handle_info/2 callback from gen_server.
handle_info(_Info, _State) ->
    {noreply, _State}.

% terminate/2 callback from gen_server.
terminate(_Reason, _State) ->
    ok.

% code_change/3 callback from gen_server.
code_change(_OldVsn, _State, _Extra) ->
    {ok, _State}.

%%%%%%%%%%%%%%%%%%%%
% Internal functions
%%%%%%%%%%%%%%%%%%%%

% Ensures mnesia db is running.
% Returns:
%   ok | {error, Reason}
ensure_started() -> 
    mnesia:start(),
    wait_for(start).

% Ensures mnesia db is not running.
% Returns:
%   ok | {error, Reason}
ensure_stopped() -> 
    mnesia:stop(),
    wait_for(stop).

% Wait for mnesia db to start/stop.
% Returns:
%   ok | {error, Reason}
wait_for(start) -> 
    case mnesia:system_info(is_running) of
        yes -> ok;
        no -> {error, mnesia_unexpectedly_not_running};
        stopping -> {error, mnesia_unexpectedly_stopping};
        starting -> 
            timer:sleep(1000),
            wait_for(start)
    end;
wait_for(stop) -> 
    case mnesia:system_info(is_running) of
        no -> ok;
        yes -> {error, mnesia_unexpectedly_running};
        starting -> {error, mnesia_unexpectedly_starting};
        stopping -> 
            timer:sleep(1000),
            wait_for(stop)
    end.

% Creates a mnesia scheme as disc_copies.
% Returns:
%   ok | {error, Reason}
create_schema() -> 
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, _, _}} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

% Deletes a mnesia scheme.
% Returns:
%   ok | {error, Reason}
delete_schema() -> 
    mnesia:delete_schema([node()]).

% Init all the tables for the tuple space.
% Returns:
%   ok | {error, Reason}
init_tables() -> 
    case mnesia:create_table(
        tuples_table, 
        [
            {type, bag}, 
            {disc_copies, [node()]}
        ]) of
            {atomic, ok} -> ok;
            {aborted, Reason} -> {error, Reason}
    end.

% Ensure all the tables are loaded before using them.
% Returns:
%   ok | {error, Reason}
ensure_tables() -> 
    case mnesia:wait_for_tables([tuples_table], 2000) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        {timeout, _} -> {error, ensure_tables_timeout}
    end.

% Copies all the tables from the space.
% Returns:
%   ok | {error, Reason}
copy_tables() -> 
    case mnesia:add_table_copy(tuples_table, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, tuples_table, _}} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

% Connects this node to the given space.
% Returns:
%   ok | {error, Reason}
connect(Node) when is_atom(Node) -> 
    case mnesia:change_config(extra_db_nodes, [Node]) of
        {ok, [_]} -> ok;
        {ok, []} -> {error, connection_failed};
        {error, Reason} -> {error, Reason}
    end.

% In case of an error reverts the mnesia db
% to a consistent state.
revert_db() ->
    ensure_stopped(),
    delete_schema(),
    ensure_started().

% List all nodes connected to the current tuple space.
% Returns:
%   [Node]
list_connected_nodes() ->
    mnesia:system_info(running_db_nodes).

% Create a new tuple space no matter if we are in one already.
% This function will return ok or throw a badmatch
% error if any of his operations goes wrong.
do_create_new_space() ->
    ok = ensure_stopped(),
    ok = delete_schema(),
    ok = ensure_started(),
    ok = create_schema(),
    ok = init_tables(),
    ok = ensure_tables().

% Remove old tuple space if exist and join the new one 
% coping all the tables.
% This function will return ok or throw a badmatch
% error if any of his operations goes wrong.
do_add_node(Node) when is_atom(Node) ->
    ok = ensure_stopped(),
    ok = delete_schema(),
    ok = ensure_started(),
    ok = connect(Node),
    ok = create_schema(),
    ok = copy_tables(),
    ok = ensure_tables().

% Deleting the schema it's the only thing in order 
% to exit from the tuple space.
% This function will return ok or throw a badmatch
% error if any of his operations goes wrong.
do_remove_node() ->
    ok = ensure_stopped(),
    ok = delete_schema(),
    ok = ensure_started().
-module(pwd_search).

-export([
    pwd_search_task/3,
    init_spaces/0,
    populate_pwd/1,
    master_task/1,
    worker_task/0
]).

% Perform the password search test case
% NOTE: This code is run by the supervisor node
pwd_search_task(NMasters, NWorkers, NPwds) ->
    nodelib:init_sup(),
    {Masters, Workers} = nodelib:spawn_nodes(NMasters, NWorkers),
    lists:foreach(fun(N) ->
        ok = rpc:call(N, proflib, start, ["./profiler/pwd/"])
    end, Masters++Workers),

    pwd_search:init_spaces(),
    Hashes = pwd_search:populate_pwd(NPwds),

    % TODO: Figure out the termination with 2 or more masters
    lists:foreach(fun(Node) ->
        nodelib:run_on_node(Node, fun() ->
            {Time,_} = timer:tc(pwd_search, master_task, [Hashes]),
            io:format("Node ~p took ~pus~n", [node(), Time])
        end)
    end, Masters),

    lists:foreach(fun(Node) ->
        nodelib:run_on_node(Node, fun() ->
            {Time,_} = timer:tc(pwd_search, worker_task, []),
            io:format("Node ~p took ~pus~n", [node(), Time])
        end)
    end, Workers),

    nodelib:wait_for_nodes(NMasters),
    ok.

% Initialize the needed spaces
init_spaces() ->
    ok = ts:new(pwd_space),
    ok = ts:new(task_space),
    lists:foreach(fun(Node) ->
        ok = ts:addNode(pwd_space, Node),
        ok = ts:addNode(task_space, Node)
    end, nodes()).

% Populate the database with N passwords and hashes
populate_pwd(N) ->
    lists:map(fun(PwdInt) -> 
        Pwd = integer_to_list(PwdInt),
        Hash = create_hash(Pwd),
        ok = ts:out(pwd_space, {Pwd, Hash}),
        Hash
    end, lists:seq(0,N-1)).

% Task run by the master node
% NOTE: This code is run by the master node
master_task(Hashes) -> 
    % sends hash requests to workers
    lists:foreach(fun(Hash) ->
        proflib:begine(write_task),
        ok = ts:out(task_space, {search_task, Hash}),
        proflib:ende(write_task)
    end, Hashes),

    io:format("Node '~p' has sent all his requests~n", [node()]),

    % wait for worker to respond with passwords
    wait_for_passwords(length(Hashes)),
    ok.

% Task run by the worker node
% NOTE: This code is run by the worker node
worker_task() ->
    % wait for new hash to search
    {ok, {search_task, Hash}} = ts:in(task_space,{search_task, any}),
    
    % find the pwd for given hash in the pwd_space
    proflib:begine(read_pwd),
    {ok, {Pwd, _Hash}} = ts:rd(pwd_space, {any,Hash}),
    proflib:ende(read_pwd),
    
    % respond with the found password
    proflib:begine(write_pwd),
    ok = ts:out(task_space, {found_password, Hash, Pwd}),
    proflib:ende(write_pwd),
    
    % search next hash
    worker_task(),
    ok.

% Return a string hash from some data
create_hash(Data) ->
    io_lib:format("~64.16.0b", 
        [binary:decode_unsigned(crypto:hash(sha256, Data))]).

% Wait for workers to find N passwords then finish the task
wait_for_passwords(0) -> 
    case nodelib:get_supervisor() of
        undefined -> exit({supervisor_undefined});
        Pid -> Pid!{finished, node()}
    end,
    ok;
wait_for_passwords(N) ->
    {ok, {found_password, _Hash, _Pwd}} = ts:in(task_space, {found_password, any, any}),
    wait_for_passwords(N-1).
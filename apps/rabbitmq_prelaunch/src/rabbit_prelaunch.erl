-module(rabbit_prelaunch).

-include_lib("eunit/include/eunit.hrl").

-export([run_prelaunch_first_phase/0,
         get_context/0,
         shutdown_func/1]).

-define(PT_KEY_CONTEXT,       {?MODULE, context}).
-define(PT_KEY_SHUTDOWN_FUNC, {?MODULE, chained_shutdown_func}).

run_prelaunch_first_phase() ->
    try
        do_run()
    catch
        throw:{error, _} = Error ->
            rabbit_prelaunch_errors:log_error(Error),
            Error;
        Class:Exception:Stacktrace ->
            rabbit_prelaunch_errors:log_exception(
              Class, Exception, Stacktrace),
            {error, Exception}
    end.

do_run() ->
    %% Configure dbg if requested.
    rabbit_prelaunch_early_logging:enable_quick_dbg(rabbit_env:dbg_config()),

    %% Get informations to setup logging.
    Context0 = rabbit_env:get_context_before_logging_init(),
    ?assertMatch(#{}, Context0),

    %% Setup logging for the prelaunch phase.
    ok = rabbit_prelaunch_early_logging:setup_early_logging(Context0, true),
    rabbit_env:log_process_env(),

    %% Load rabbitmq-env.conf, redo logging setup and continue.
    Context1 = rabbit_env:get_context_after_logging_init(Context0),
    ?assertMatch(#{}, Context1),
    ok = rabbit_prelaunch_early_logging:setup_early_logging(Context1, true),
    rabbit_env:log_process_env(),

    %% Complete context now that we have the final environment loaded.
    Context = rabbit_env:get_context_after_reloading_env(Context1),
    ?assertMatch(#{}, Context),
    store_context(Context),
    rabbit_env:log_context(Context),
    ok = setup_shutdown_func(),

    rabbit_env:context_to_code_path(Context),
    rabbit_env:context_to_app_env_vars(Context),

    %% Stop Mnesia now. It is started because `rabbit` depends on
    %% it. But because distribution is not configured yet at the
    %% time it is started, it is non-functionnal. Having Mnesia
    %% started also messes with cluster consistency checks.
    %%
    %% We can stop it now and start it again at the end of
    %% rabbit:run_prelaunch_second_phase().
    rabbit_log_prelaunch:debug(
      "Ensuring Mnesia is stopped (to permit Erlang distribution setup "
      "& cluster checks"),
    stopped = mnesia:stop(),

    %% 1. Erlang/OTP compatibility check.
    ok = rabbit_prelaunch_erlang_compat:check(Context),

    %% 2. Erlang distribution check + start
    ok = rabbit_prelaunch_dist:setup(Context),

    %% 3. Write PID file.
    _ = write_pid_file(Context),
    ignore.

store_context(Context) when is_map(Context) ->
    persistent_term:put(?PT_KEY_CONTEXT, Context).

get_context() ->
    persistent_term:get(?PT_KEY_CONTEXT, undefined).

setup_shutdown_func() ->
    ThisMod = ?MODULE,
    ThisFunc = shutdown_func,
    ExistingShutdownFunc = application:get_env(kernel, shutdown_func),
    case ExistingShutdownFunc of
        {ok, {ThisMod, ThisFunc}} ->
            ok;
        {ok, {ExistingMod, ExistingFunc}} ->
            rabbit_log_prelaunch:debug(
              "Setting up kernel shutdown function: ~s:~s/1 "
              "(chained with ~s:~s/1)",
              [ThisMod, ThisFunc, ExistingMod, ExistingFunc]),
            ok = persistent_term:put(
                   ?PT_KEY_SHUTDOWN_FUNC,
                   ExistingShutdownFunc),
            ok = record_kernel_shutdown_func(ThisMod, ThisFunc);
        _ ->
            rabbit_log_prelaunch:debug(
              "Setting up kernel shutdown function: ~s:~s/1",
              [ThisMod, ThisFunc]),
            ok = record_kernel_shutdown_func(ThisMod, ThisFunc)
    end.

record_kernel_shutdown_func(Mod, Func) ->
    application:set_env(
      kernel, shutdown_func, {Mod, Func},
      [{persistent, true}]).

shutdown_func(Reason) ->
    rabbit_log_prelaunch:debug(
      "Running ~s:shutdown_func() as part of `kernel` shutdown", [?MODULE]),
    Context = get_context(),
    remove_pid_file(Context),
    ChainedShutdownFunc = persistent_term:get(
                            ?PT_KEY_SHUTDOWN_FUNC,
                            undefined),
    case ChainedShutdownFunc of
        {ChainedMod, ChainedFunc} -> ChainedMod:ChainedFunc(Reason);
        _                         -> ok
    end.

write_pid_file(#{pid_file := PidFile}) ->
    rabbit_log_prelaunch:debug("Writing PID file: ~s", [PidFile]),
    case filelib:ensure_dir(PidFile) of
        ok ->
            OSPid = os:getpid(),
            case file:write_file(PidFile, OSPid) of
                ok ->
                    ok;
                {error, Reason} = Error ->
                    rabbit_log_prelaunch:warning(
                      "Failed to write PID file \"~s\": ~s",
                      [PidFile, file:format_error(Reason)]),
                    Error
            end;
        {error, Reason} = Error ->
            rabbit_log_prelaunch:warning(
              "Failed to create PID file \"~s\" directory: ~s",
              [PidFile, file:format_error(Reason)]),
            Error
    end;
write_pid_file(_) ->
    ok.

remove_pid_file(#{pid_file := PidFile, keep_pid_file_on_exit := true}) ->
    rabbit_log_prelaunch:debug("Keeping PID file: ~s", [PidFile]),
    ok;
remove_pid_file(#{pid_file := PidFile}) ->
    rabbit_log_prelaunch:debug("Deleting PID file: ~s", [PidFile]),
    _ = file:delete(PidFile);
remove_pid_file(_) ->
    ok.

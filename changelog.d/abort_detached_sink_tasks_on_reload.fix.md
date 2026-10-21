Fixed sink tasks being orphaned during config reload. When a sink was removed or
replaced and its old task did not finish draining within the reload drain timeout,
the task was detached and kept running (and retrying a permanently failing request)
until the process exited. Detached sink tasks are now aborted once the drain timeout
elapses.

authors: walthowd

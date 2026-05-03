defmodule SymphonyElixir.AgentEnvTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentEnv

  test "resolve returns an empty env when nothing is configured" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, []} = AgentEnv.resolve()
  end

  test "resolve forwards configured passthrough vars from the orchestrator env" do
    var_name = "SYMPHONY_AGENTENV_TEST_#{System.unique_integer([:positive])}"
    previous = System.get_env(var_name)
    on_exit(fn -> restore_env(var_name, previous) end)
    System.put_env(var_name, "value-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(), agent_env_passthrough: [var_name])

    assert {:ok, env} = AgentEnv.resolve()
    assert {^var_name, value} = Enum.find(env, fn {name, _value} -> name == var_name end)
    assert value == System.get_env(var_name)
  end

  test "resolve drops passthrough vars that are unset or empty" do
    var_name = "SYMPHONY_AGENTENV_MISSING_#{System.unique_integer([:positive])}"
    System.delete_env(var_name)

    write_workflow_file!(Workflow.workflow_file_path(), agent_env_passthrough: [var_name])

    assert {:ok, env} = AgentEnv.resolve()
    refute Enum.any?(env, fn {name, _value} -> name == var_name end)
  end

  test "resolve returns an error when a configured keychain entry is missing" do
    missing_entry = "symphony-keychain-missing-#{System.unique_integer([:positive])}"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_gh_token_keychain: missing_entry
    )

    assert {:error, reason} = AgentEnv.resolve()
    assert match?({:keychain_entry_not_found, ^missing_entry, _status}, reason)
  end

  test "validate! raises with a clear message when the keychain entry is missing" do
    missing_entry = "symphony-keychain-missing-#{System.unique_integer([:positive])}"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_gh_token_keychain: missing_entry
    )

    assert_raise ArgumentError, ~r/agent\.gh_token_keychain configured but unreadable/, fn ->
      AgentEnv.validate!()
    end
  end

  test "validate! is a no-op when no keychain is configured" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert :ok = AgentEnv.validate!()
  end
end

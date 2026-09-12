defmodule SharedInfra.BuildInfo do
  @moduledoc """
  Which build is this?

  "Is the new image actually running?" was a manual `rpc` + `grep` exercise three times in one day.
  The SHA now rides every health response, so one `curl` answers it.

  HOW THE VALUE GETS HERE: the EC2 box builds from a git checkout, but the Dockerfile COPYs `apps/`
  and `config/` — not `.git` — so nothing inside the build can read git. The SHA is passed in as a
  build arg and kept as an ENV in the runtime stage (see apps/backend/Dockerfile); this reads that
  env.
  """

  @doc """
  The git SHA of the running build, or "unknown".

  READ AT CALL TIME, never a module attribute. A module attribute would freeze whatever `GIT_SHA`
  was set during COMPILATION — which in a release is the build container, not the deployed one — and
  the value would then be a confident lie about a different build. The same rule the rest of the
  codebase applies to env config (V1_RATE_LIMIT, RT_* limits): read it where it is used.

  Always a string. An absent or empty env answers "unknown" rather than nil, so every consumer can
  render it without a nil branch and a build with no SHA passed in is still a build that reports.
  """
  @spec git_sha() :: String.t()
  def git_sha do
    case System.get_env("GIT_SHA") do
      value when is_binary(value) and value != "" -> value
      _ -> "unknown"
    end
  end
end

defmodule NotificationService.FcmFakes do
  @moduledoc """
  Test doubles for the FCM leg. An FCM send must NEVER be attempted from a test run, and the
  presence gates must be assertable without standing up Redis — both are swapped through the same
  application-env seams the repo already uses for `:auth_client_adapter`.
  """

  defmodule Http do
    @moduledoc """
    Records every request to the test process and answers from a queue the test controls.

    `post_form/2` (the OAuth token exchange) always succeeds — the JWT-bearer round trip is Google's,
    not ours, and stubbing it keeps every send test focused on the FCM envelope.
    """
    @behaviour NotificationService.FcmSender.Http

    @impl true
    def post(url, body, access_token) do
      send(test_pid(), {:fcm_post, url, body, access_token})

      case Process.get(:fcm_responses) do
        [response | rest] ->
          Process.put(:fcm_responses, rest)
          response

        _ ->
          {:ok, %{status: 200, body: %{"name" => "projects/p/messages/1"}}}
      end
    end

    @impl true
    def post_form(_url, _form) do
      {:ok, %{status: 200, body: %{"access_token" => "test-access-token", "expires_in" => 3600}}}
    end

    defp test_pid, do: Process.get(:fcm_test_pid) || self()
  end

  defmodule PresentEverywhere do
    @moduledoc "The recipient's app is foreground — the web leg would suppress, so must this one."
    def app_present?(_user_id), do: true
    def present?(_user_id, _conversation_id), do: true
  end

  defmodule ViewingThisChat do
    @moduledoc "App not foreground by the app-level marker, but viewing THIS conversation."
    def app_present?(_user_id), do: false
    def present?(_user_id, _conversation_id), do: true
  end

  defmodule Absent do
    @moduledoc """
    Nobody is present. Also the shape of a Redis OUTAGE, because `PresenceMarker` fails open —
    a miss reads as absent and we send.
    """
    def app_present?(_user_id), do: false
    def present?(_user_id, _conversation_id), do: false
  end

  @doc """
  Point the FCM leg at the fakes and give it a working (throwaway) service-account credential, so
  `configured?/0` is true and the JWT assertion actually signs. Restores everything on exit.
  """
  def configure!(context \\ %{}) do
    presence = Map.get(context, :presence, Absent)
    previous_fcm = Application.get_env(:notification_service, :fcm)

    Application.put_env(:notification_service, :fcm,
      project_id: "test-project",
      credentials: %{
        "client_email" => "fcm-test@test-project.iam.gserviceaccount.com",
        "private_key" => test_private_key()
      }
    )

    Application.put_env(:notification_service, :fcm_http, Http)
    Application.put_env(:notification_service, :fcm_presence, presence)

    Process.put(:fcm_test_pid, self())
    # A fresh access token per test — otherwise a cached one leaks between them.
    :persistent_term.erase({NotificationService.FcmSender, :access_token})

    ExUnit.Callbacks.on_exit(fn ->
      if previous_fcm,
        do: Application.put_env(:notification_service, :fcm, previous_fcm),
        else: Application.delete_env(:notification_service, :fcm)

      Application.delete_env(:notification_service, :fcm_http)
      Application.delete_env(:notification_service, :fcm_presence)
      :persistent_term.erase({NotificationService.FcmSender, :access_token})
    end)

    :ok
  end

  @doc "Queue the responses the next FCM sends will get (in order)."
  def respond_with(responses), do: Process.put(:fcm_responses, responses)

  # Generated once per run rather than checked in — a committed private key, even a throwaway, is a
  # committed private key.
  defp test_private_key do
    case :persistent_term.get({__MODULE__, :pem}, nil) do
      pem when is_binary(pem) ->
        pem

      _ ->
        {_meta, pem} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem()
        :persistent_term.put({__MODULE__, :pem}, pem)
        pem
    end
  end
end

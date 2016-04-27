defmodule Slack do
  @moduledoc """
  Slack is a genserver-ish interface for working with the Slack real time
  messaging API through a Websocket connection.

  To use this module you'll need a valid Slack API token. You can find your
  personal token on the [Slack Web API] page, or you can add a new
  [bot integration].

  [Slack Web API]: https://api.slack.com/web
  [bot integration]: https://api.slack.com/bot-users

  ## Example

  ```
  defmodule Bot do
    use Slack

    def handle_message(message = {type: "message"}, slack, state) do
      if message.text == "Hi" do
        send_message("Hi has been said #\{state} times", message.channel, slack)
        state = state + 1
      end

      {:ok, state}
    end
  end

  Bot.start_link("API_TOKEN", 1)
  ```

  `handle_*` methods are always passed `slack` and `state` arguments. The
  `slack` argument holds the state of Slack and is kept up to date
  automatically.

  In this example we're just matching against the message type and checking if
  the text content is "Hi" and if so, we reply with how many times "Hi" has been
  said.

  The message type is pattern matched against because the
  [Slack RTM API](https://api.slack.com/rtm) defines many different types of
  messages that we can receive. Because of this it's wise to write a catch-all
  `handle_message/3` in your bots to prevent crashing.

  ## Callbacks

  * `handle_connect(slack, state)` - called when connected to Slack.
  * `handle_message(message, slack, state)` - called when a message is received.
  * `handle_close(reason, slack, state)` - called when websocket is closed.
  * `handle_info(message, slack, state)` - called when any other message is received in the process mailbox.

  ## Slack argument

  The Slack argument that's passed to each callback is what contains all of the
  state related to Slack including a list of channels, users, groups, bots, and
  even the socket.

  Here's a list of what's stored:

  * me - The current bot/users information stored as a map of properties.
  * team - The current team's information stored as a map of properties.
  * bots - Stored as a map with id's as keys.
  * channels - Stored as a map with id's as keys.
  * groups - Stored as a map with id's as keys.
  * users - Stored as a map with id's as keys.
  * socket - The connection to Slack.
  * client - The client that makes calls to Slack.

  For all but `socket` and `client`, you can see what types of data to expect each of the
  types to contain from the [Slack API types] page.

  [Slack API types]: https://api.slack.com/types
  """
  defmacro __using__(_) do
    quote do
      @behaviour :websocket_client_handler
      import Slack
      import Slack.Handlers

      def start_link(token, initial_state, client \\ :websocket_client) do
        case Slack.Rtm.start(token) do
          {:ok, rtm} ->
            state = %{
              rtm: rtm,
              state: initial_state,
              client: client,
              token: token
            }
            url = String.to_char_list(rtm.url)
            client.start_link(url, __MODULE__, state)
          {:error, %HTTPoison.Error{reason: :connect_timeout}} ->
            {:error, "Timed out while connecting to the Slack RTM API"}
          {:error, %HTTPoison.Error{reason: :nxdomain}} ->
            {:error, "Could not connect to the Slack RTM API"}
          {:error, error} ->
            {:error, error}
        end
      end

      def init(%{rtm: rtm, client: client, state: state, token: token}, socket) do
        slack = %{
          socket: socket,
          client: client,
          token: token,
          me: rtm.self,
          team: rtm.team,
          bots: rtm_list_to_map(rtm.bots),
          channels: rtm_list_to_map(rtm.channels),
          groups: rtm_list_to_map(rtm.groups),
          users: rtm_list_to_map(rtm.users),
          ims: rtm_list_to_map(rtm.ims)
        }

        {:ok, state} = handle_connect(slack, state)
        {:ok, %{slack: slack, state: state}}
      end

      def websocket_info(:start, _connection, state) do
        {:ok, state}
      end

      def websocket_info(message, _connection, %{slack: slack, state: state}) do
        {:ok, state} = handle_info(message, slack, state)
        {:ok, %{slack: slack, state: state}}
      end

      def websocket_terminate(reason, _connection, %{slack: slack, state: state}) do
        handle_close(reason, slack, state)
      end

      def websocket_handle({:ping, data}, _connection, state) do
        {:reply, {:pong, data}, state}
      end

      def websocket_handle({:text, message}, _con, %{slack: slack, state: state}) do
        message = prepare_message message
        if Map.has_key?(message, :type) do
          {:ok, slack} = handle_slack(message, slack)
          {:ok, state} = handle_message(message, slack, state)
        end

        {:ok, %{slack: slack, state: state}}
      end

      defp rtm_list_to_map(list) do
        Enum.reduce(list, %{}, fn (item, map) ->
          Map.put(map, item.id, item)
        end)
      end

      defp prepare_message(binstring) do
        binstring
          |> :binary.split(<<0>>)
          |> List.first
          |> JSX.decode!([{:labels, :atom}])
      end

      def handle_connect(_slack, state), do: {:ok, state}
      def handle_message(_message, _slack, state), do: {:ok, state}
      def handle_close(_reason, _slack, state), do: {:error, state}
      def handle_info(_message, _slack, state), do: {:ok, state}

      defoverridable [handle_connect: 2, handle_message: 3, handle_close: 3, handle_info: 3]
    end
  end

  @doc ~S"""
  Turns a string like `"@USER_NAME"` into the ID that Slack understands (`"U…"`).
  """
  def lookup_user_id("@" <> user_name, slack) do
    slack.users
    |> Map.values
    |> Enum.find(%{ }, fn user -> user.name == user_name end)
    |> Map.get(:id)
  end

  @doc ~S"""
  Turns a string like `"@USER_NAME"` or a user ID (`"U…"`) into the ID for the
  direct message channel of that user (`"D…"`).  `nil` is returned if a direct
  message channel has not yet been opened.
  """
  def lookup_direct_message_id(user = "@" <> _user_name, slack) do
    user
    |> lookup_user_id(slack)
    |> lookup_direct_message_id(slack)
  end
  def lookup_direct_message_id(user_id, slack) do
    slack.ims
    |> Map.values
    |> Enum.find(%{ }, fn direct_message -> direct_message.user == user_id end)
    |> Map.get(:id)
  end

  @doc ~S"""
  Turns a string like `"@CHANNEL_NAME"` into the ID that Slack understands
  (`"C…"`).
  """
  def lookup_channel_id("#" <> channel_name, slack) do
    slack.channels
    |> Map.values
    |> Enum.find(fn channel -> channel.name == channel_name end)
    |> Map.get(:id)
  end

  @doc ~S"""
  Turns a Slack user ID (`"U…"`) or direct message ID (`"D…"`) into a string in
  the format "@USER_NAME".
  """
  def lookup_user_name(direct_message_id = "D" <> _id, slack) do
    lookup_user_name(slack.ims[direct_message_id].user, slack)
  end
  def lookup_user_name(user_id = "U" <> _id, slack) do
    "@" <> slack.users[user_id].name
  end

  @doc ~S"""
  Turns a Slack channel ID (`"C…"`) into a string in the format "#CHANNEL_NAME".
  """
  def lookup_channel_name(channel_id = "C" <> _id, slack) do
    "#" <> slack.channels[channel_id].name
  end

  @doc """
  Sends `text` to `channel` for the given `slack` connection.  `channel` can be
  a string in the format of `"#CHANNEL_NAME"`, `"@USER_NAME"`, or any ID that
  Slack understands.
  """
  def send_message(text, channel = "#" <> channel_name, slack) do
    channel_id = lookup_channel_id(channel, slack)
    if channel_id do
      send_message(text, channel_id, slack)
    else
      raise ArgumentError, "channel ##{channel_name} not found"
    end
  end
  def send_message(text, user = "@" <> user_name, slack) do
    direct_message_id = lookup_direct_message_id(user, slack)
    if direct_message_id do
      send_message(text, direct_message_id, slack)
    else
      im_open = HTTPoison.post(
        "https://slack.com/api/im.open",
        {:form, [token: slack.token, user: lookup_user_id(user, slack)]}
      )
      case im_open do
        {:ok, response} ->
          case JSX.decode!(response.body, [{:labels, :atom}]) do
            %{ok: true, channel: %{id: id}} -> send_message(text, id, slack)
            _ -> :delivery_failed
          end
        {:error, reason} -> :delivery_failed
      end
    end
  end
  def send_message(text, channel, slack) do
    %{
      type: "message",
      text: text,
      channel: channel
    }
      |> JSX.encode!
      |> send_raw(slack)
  end

  @doc """
  Notifies Slack that the current user is typing in `channel`.
  """
  def indicate_typing(channel, slack) do
    %{
      type: "typing",
      channel: channel
    }
      |> JSX.encode!
      |> send_raw(slack)
  end

  @doc """
  Notifies slack that the current `slack` user is typing in `channel`.
  """
  def send_ping(data \\ [], slack) do
    %{
      type: "ping"
    }
      |> Dict.merge(data)
      |> JSX.encode!
      |> send_raw(slack)
  end

  @doc """
  Sends raw JSON to a given socket.
  """
  def send_raw(json, %{socket: socket, client: client}) do
    client.send({:text, json}, socket)
  end
end

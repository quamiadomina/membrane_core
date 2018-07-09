defmodule Membrane.Core.Element.PlaybackBuffer do
  alias Membrane.Core.Playback
  alias Membrane.{Buffer, Core, Event}

  alias Core.Element.{
    BufferController,
    CapsController,
    DemandController,
    EventController,
    PadModel,
    State
  }

  require PadModel
  use Core.Element.Log
  use Membrane.Helper

  @type t :: %__MODULE__{
          q: Qex.t()
        }

  defstruct q: nil

  @qe Qex

  def new do
    %__MODULE__{q: @qe.new}
  end

  def store(msg, %State{playback: %Playback{state: :playing}} = state), do: exec(msg, state)

  def store({type, _args} = msg, state)
      when type in [:membrane_event, :membrane_caps] do
    exec(msg, state)
    |> provided(
      that: state.playback_buffer |> empty?,
      else:
        state
        |> Helper.Struct.update_in([:playback_buffer, :q], fn q -> q |> @qe.push(msg) end)
        ~> (state -> {:ok, state})
    )
  end

  def store(msg, state) do
    state
    |> Helper.Struct.update_in([:playback_buffer, :q], fn q -> q |> @qe.push(msg) end)
    ~> (state -> {:ok, state})
  end

  def eval(%State{playback: %Playback{state: :playing}} = state) do
    debug("evaluating playback buffer", state)

    with {:ok, state} <-
           state.playback_buffer.q
           |> Helper.Enum.reduce_with(state, &exec/2),
         do: {:ok, state |> Helper.Struct.put_in([:playback_buffer, :q], @qe.new)}
  end

  def eval(state), do: {:ok, state}

  def empty?(%__MODULE__{q: q}), do: q |> Enum.empty?()

  # Callback invoked on demand request coming from the source pad in the pull mode
  defp exec({:membrane_demand, [size, pad_name]}, state) do
    {:ok, _} = PadModel.get_data(pad_name, %{direction: :source}, state)

    demand =
      if size == 0 do
        "dumb demand"
      else
        "demand of size #{inspect(size)}"
      end

    debug("Received #{demand} on pad #{inspect(pad_name)}", state)
    DemandController.handle_demand(pad_name, size, state)
  end

  # Callback invoked on buffer coming through the sink pad
  defp exec({:membrane_buffer, [buffers, pad_name]}, state) do
    PadModel.assert_data!(pad_name, %{direction: :sink}, state)

    debug(
      ["
      Received buffers on pad #{inspect(pad_name)}
      Buffers: ", Buffer.print(buffers)],
      state
    )

    {{:ok, messages}, state} =
      PadModel.get_and_update_data(pad_name, :sticky_messages, &{{:ok, []}, &1}, state)

    with {:ok, state} <-
           messages
           |> Enum.reverse()
           |> Helper.Enum.reduce_with(state, fn msg, st -> msg.(st) end) do
      {:ok, state} =
        cond do
          PadModel.get_data!(pad_name, :sos, state) |> Kernel.not() ->
            event = %{Event.sos() | payload: :auto_sos}
            EventController.handle_event(pad_name, event, state)

          true ->
            {:ok, state}
        end

      BufferController.handle_buffer(pad_name, buffers, state)
    end
  end

  # Callback invoked on incoming caps
  defp exec({:membrane_caps, [caps, pad_name]}, state) do
    PadModel.assert_data!(pad_name, %{direction: :sink}, state)

    debug(
      """
      Received caps on pad #{inspect(pad_name)}
      Caps: #{inspect(caps)}
      """,
      state
    )

    CapsController.handle_caps(pad_name, caps, state)
  end

  # Callback invoked on incoming event
  defp exec({:membrane_event, [event, pad_name]}, state) do
    PadModel.assert_instance!(pad_name, state)

    debug(
      """
      Received event on pad #{inspect(pad_name)}
      Event: #{inspect(event)}
      """,
      state
    )

    do_exec = fn state ->
      EventController.handle_event(pad_name, event, state)
    end

    case event.stick_to do
      :nothing ->
        do_exec.(state)

      :buffer ->
        PadModel.update_data(
          pad_name,
          :sticky_messages,
          &{:ok, [do_exec | &1]},
          state
        )
    end
  end
end

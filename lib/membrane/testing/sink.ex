defmodule Membrane.Testing.Sink do
  @moduledoc """
  Sink Element that will send every buffer it receives to the pid passed as argument.
  """

  use Membrane.Element.Base.Sink

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_options autodemand: [
                type: :boolean,
                default: true,
                description: """
                If true element will automatically make demands.
                If it is set to false demand has to be triggered manually by sending `:make_demand` message.
                """
              ]

  @impl true
  def handle_init(opts) do
    {:ok, opts}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{autodemand: true} = state),
    do: {{:ok, demand: :input}, state}

  def handle_prepared_to_playing(_context, state), do: {:ok, state}

  @impl true
  def handle_other({:make_demand, size}, _ctx, %{autodemand: false} = state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_write(:input, buf, _ctx, state) do
    case state do
      %{autodemand: false} -> {{:ok, notify: buf}, state}
      %{autodemand: true} -> {{:ok, demand: :input, notify: buf}, state}
    end
  end
end

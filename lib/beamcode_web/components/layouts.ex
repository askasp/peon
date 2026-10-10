defmodule BeamcodeWeb.Layouts do
  @moduledoc """
  The page shell for the server-rendered pages (login, errors) and the Peon
  wordmark. Everything else is the Expo app at `/app`.
  """
  use BeamcodeWeb, :html

  embed_templates "layouts/*"

  @doc """
  The Peon wordmark with its "work work." tagline (design 4b).
  `sm` sits on one line at the top of the sidebar; `lg` stacks for the login page.
  """
  attr :size, :string, default: "sm", values: ~w(sm lg)

  def logo(assigns) do
    ~H"""
    <span
      id={"logo-" <> @size}
      class={[
        "flex select-none",
        if(@size == "lg", do: "flex-col items-start gap-1.5", else: "items-baseline gap-2")
      ]}
    >
      <span class={[
        "font-brand font-bold tracking-[-0.04em] leading-none text-fg",
        if(@size == "lg", do: "text-[44px]", else: "text-[24px]")
      ]}>
        peon
      </span>
      <span class={[
        "font-tagline text-key whitespace-nowrap",
        if(@size == "lg", do: "text-[13px]", else: "text-[11px]")
      ]}>
        work work.
      </span>
    </span>
    """
  end
end

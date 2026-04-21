defmodule Vector.Games.Morris.Board do
  @moduledoc "Three Men's Morris board — 9 positions on a 3x3 grid."

  # Positions: 0-8 (top-left to bottom-right)
  # Mills: rows, cols, diagonals
  @mills [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],  # rows
    [0, 3, 6], [1, 4, 7], [2, 5, 8],  # cols
    [0, 4, 8], [2, 4, 6]              # diagonals
  ]

  def initial_state do
    %{
      board: List.duplicate(nil, 9),
      current_turn: "white",
      phase: "placing",
      pieces_placed: %{"white" => 0, "black" => 0},
      pieces_on_board: %{"white" => 0, "black" => 0},
      status: "active"
    }
  end

  def mills, do: @mills
end

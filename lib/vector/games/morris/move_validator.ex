defmodule Vector.Games.Morris.MoveValidator do
  @moduledoc "Three Men's Morris move validation and game logic."

  alias Vector.Games.Morris.Board

  @pieces_per_player 3

  def valid_move?(state, move, player_color) do
    board = state["board"]
    phase = state["phase"]

    case phase do
      "placing" -> valid_place?(board, move, player_color, state)
      "moving" -> valid_move_piece?(board, move, player_color)
      _ -> false
    end
  end

  def apply_move(state, move) do
    board = state["board"]
    phase = state["phase"]
    color = state["current_turn"]
    next_turn = if color == "white", do: "black", else: "white"

    {new_board, new_state} =
      case phase do
        "placing" ->
          pos = move["to"]
          new_board = List.replace_at(board, pos, color)
          placed = get_in(state, ["pieces_placed", color]) + 1
          on_board = get_in(state, ["pieces_on_board", color]) + 1

          updated_state =
            state
            |> put_in(["pieces_placed", color], placed)
            |> put_in(["pieces_on_board", color], on_board)

          total_placed = placed + get_in(state, ["pieces_placed", next_turn])

          new_phase =
            if total_placed >= @pieces_per_player * 2, do: "moving", else: "placing"

          {new_board, Map.put(updated_state, "phase", new_phase)}

        "moving" ->
          from = move["from"]
          to = move["to"]
          new_board = board |> List.replace_at(from, nil) |> List.replace_at(to, color)
          {new_board, state}
      end

    updated =
      new_state
      |> Map.put("board", new_board)
      |> Map.put("current_turn", next_turn)

    {:ok, updated}
  end

  def check_game_over(state) do
    board = state["board"]
    current = state["current_turn"]

    cond do
      forms_mill?(board, "white") -> {:finished, "white_wins"}
      forms_mill?(board, "black") -> {:finished, "black_wins"}
      state["phase"] == "moving" and no_moves?(board, current) ->
        winner = if current == "white", do: "black", else: "white"
        {:finished, "#{winner}_wins"}

      true ->
        :ongoing
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp valid_place?(board, move, color, state) do
    pos = move["to"]
    placed = get_in(state, ["pieces_placed", color])
    is_integer(pos) and pos in 0..8 and is_nil(Enum.at(board, pos)) and
      placed < @pieces_per_player
  end

  defp valid_move_piece?(board, move, color) do
    from = move["from"]
    to = move["to"]

    is_integer(from) and is_integer(to) and
      Enum.at(board, from) == color and
      is_nil(Enum.at(board, to)) and
      adjacent?(from, to)
  end

  defp adjacent?(a, b) do
    adjacency = %{
      0 => [1, 3], 1 => [0, 2, 4], 2 => [1, 5],
      3 => [0, 4, 6], 4 => [1, 3, 5, 7], 5 => [2, 4, 8],
      6 => [3, 7], 7 => [4, 6, 8], 8 => [5, 7]
    }
    b in Map.get(adjacency, a, [])
  end

  defp forms_mill?(board, color) do
    Enum.any?(Board.mills(), fn [a, b, c] ->
      Enum.at(board, a) == color and
      Enum.at(board, b) == color and
      Enum.at(board, c) == color
    end)
  end

  defp no_moves?(board, color) do
    0..8
    |> Enum.filter(&(Enum.at(board, &1) == color))
    |> Enum.all?(fn from ->
      0..8
      |> Enum.filter(&(is_nil(Enum.at(board, &1))))
      |> Enum.all?(&(not adjacent?(from, &1)))
    end)
  end
end

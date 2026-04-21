defmodule Vector.Games.Chess.MoveValidator do
  @moduledoc "Basic chess move validation."

  alias Vector.Games.Chess.Board

  def valid_move?(state, move, player_color) do
    %{"from" => from, "to" => to} = move
    pieces = Board.deserialize_pieces(state["pieces"])
    from_sq = parse_square(from)
    to_sq = parse_square(to)

    with {:ok, {piece, ^player_color}} <- get_piece(pieces, from_sq),
         true <- destination_valid?(pieces, to_sq, player_color),
         true <- piece_can_move?(piece, player_color, from_sq, to_sq, pieces, state) do
      true
    else
      _ -> false
    end
  end

  def apply_move(state, move) do
    %{"from" => from, "to" => to} = move
    pieces = Board.deserialize_pieces(state["pieces"])
    from_sq = parse_square(from)
    to_sq = parse_square(to)

    {piece_data, pieces} = Map.pop(pieces, from_sq)
    pieces = Map.put(pieces, to_sq, piece_data)

    next_turn = if state["current_turn"] == "white", do: "black", else: "white"

    updated_state =
      state
      |> Map.put("pieces", Board.serialize_pieces(pieces))
      |> Map.put("current_turn", next_turn)
      |> Map.put("en_passant_target", nil)

    {:ok, updated_state}
  end

  def check_game_over(state) do
    pieces = Board.deserialize_pieces(state["pieces"])
    colors = pieces |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    cond do
      :white not in colors -> {:finished, "black_wins"}
      :black not in colors -> {:finished, "white_wins"}
      not king_exists?(pieces, :white) -> {:finished, "black_wins"}
      not king_exists?(pieces, :black) -> {:finished, "white_wins"}
      true -> :ongoing
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp parse_square([col, row]), do: {col, row}
  defp parse_square(%{"col" => col, "row" => row}), do: {col, row}

  defp get_piece(pieces, square) do
    case Map.get(pieces, square) do
      nil -> {:error, :empty}
      piece -> {:ok, piece}
    end
  end

  defp destination_valid?(pieces, to_sq, player_color) do
    case Map.get(pieces, to_sq) do
      nil -> true
      {_, ^player_color} -> false
      _ -> true
    end
  end

  defp king_exists?(pieces, color) do
    Enum.any?(pieces, fn {_, {piece, c}} -> piece == :king and c == color end)
  end

  defp piece_can_move?(:pawn, color, {fc, fr}, {tc, tr}, pieces, _state) do
    direction = if color == :white, do: 1, else: -1
    start_row = if color == :white, do: 2, else: 7

    cond do
      # Single step forward
      fc == tc and tr == fr + direction and is_nil(Map.get(pieces, {tc, tr})) ->
        true

      # Double step from start
      fc == tc and fr == start_row and tr == fr + 2 * direction and
          is_nil(Map.get(pieces, {tc, tr})) and
          is_nil(Map.get(pieces, {fc, fr + direction})) ->
        true

      # Diagonal capture
      abs(tc - fc) == 1 and tr == fr + direction ->
        case Map.get(pieces, {tc, tr}) do
          {_, cap_color} when cap_color != color -> true
          _ -> false
        end

      true ->
        false
    end
  end

  defp piece_can_move?(:rook, _color, {fc, fr}, {tc, tr}, pieces, _state) do
    (fc == tc or fr == tr) and path_clear?(pieces, {fc, fr}, {tc, tr})
  end

  defp piece_can_move?(:bishop, _color, {fc, fr}, {tc, tr}, pieces, _state) do
    abs(tc - fc) == abs(tr - fr) and path_clear?(pieces, {fc, fr}, {tc, tr})
  end

  defp piece_can_move?(:queen, color, from, to, pieces, state) do
    piece_can_move?(:rook, color, from, to, pieces, state) or
      piece_can_move?(:bishop, color, from, to, pieces, state)
  end

  defp piece_can_move?(:knight, _color, {fc, fr}, {tc, tr}, _pieces, _state) do
    {abs(tc - fc), abs(tr - fr)} in [{1, 2}, {2, 1}]
  end

  defp piece_can_move?(:king, _color, {fc, fr}, {tc, tr}, _pieces, _state) do
    abs(tc - fc) <= 1 and abs(tr - fr) <= 1
  end

  defp path_clear?(pieces, {fc, fr}, {tc, tr}) do
    dc = sign(tc - fc)
    dr = sign(tr - fr)
    steps = max(abs(tc - fc), abs(tr - fr)) - 1

    Enum.reduce_while(1..max(steps, 1), true, fn i, _ ->
      sq = {fc + i * dc, fr + i * dr}
      if i <= steps and Map.has_key?(pieces, sq), do: {:halt, false}, else: {:cont, true}
    end)
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_), do: -1
end

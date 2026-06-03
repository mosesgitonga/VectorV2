defmodule Vector.Games.Chess.MoveValidator do
  @moduledoc """
  Server-side chess move validation.

  Implements:
  - Piece movement rules (all six piece types)
  - King safety: a move that leaves your king in check is illegal
  - Checkmate detection (no legal moves + king in check)
  - Stalemate detection (no legal moves, king not in check)
  - En passant capture
  - Pawn promotion (auto-promotes to queen)
  - Writes in_check to the game state for the frontend highlight
  """

  alias Vector.Games.Chess.Board

  # ── Public API ─────────────────────────────────────────────────────────────

  def valid_move?(state, move, player_color) do
    %{"from" => from, "to" => to} = move
    pieces   = Board.deserialize_pieces(state["pieces"])
    from_sq  = parse_sq(from)
    to_sq    = parse_sq(to)
    ep       = parse_ep(state["en_passant_target"])

    with {:ok, {piece, ^player_color}} <- get_piece(pieces, from_sq),
         true <- dest_valid?(pieces, to_sq, player_color),
         true <- can_move?(piece, player_color, from_sq, to_sq, pieces, ep) do
      # King must not be in check after the move.
      pieces_after = apply_pieces(pieces, piece, player_color, from_sq, to_sq, ep)
      not in_check?(pieces_after, player_color)
    else
      _ -> false
    end
  end

  def apply_move(state, move) do
    %{"from" => from, "to" => to} = move
    pieces        = Board.deserialize_pieces(state["pieces"])
    from_sq       = parse_sq(from)
    to_sq         = parse_sq(to)
    player_color  = String.to_atom(state["current_turn"])
    ep            = parse_ep(state["en_passant_target"])

    {piece, _}   = Map.get(pieces, from_sq)
    pieces_after = apply_pieces(pieces, piece, player_color, from_sq, to_sq, ep)

    # Set new en_passant_target when a pawn double-steps.
    new_ep =
      if piece == :pawn do
        {fc, fr} = from_sq; {_tc, tr} = to_sq
        if abs(tr - fr) == 2 do
          dir = if player_color == :white, do: 1, else: -1
          {fc, fr + dir}
        else
          nil
        end
      else
        nil
      end

    next_turn  = if state["current_turn"] == "white", do: "black", else: "white"
    next_color = String.to_atom(next_turn)

    # Expose check state so the frontend can highlight the king.
    check_val = if in_check?(pieces_after, next_color), do: next_turn, else: nil

    updated =
      state
      |> Map.put("pieces", Board.serialize_pieces(pieces_after))
      |> Map.put("current_turn", next_turn)
      |> Map.put("en_passant_target", serialize_ep(new_ep))
      |> Map.put("in_check", check_val)

    {:ok, updated}
  end

  def check_game_over(state) do
    pieces       = Board.deserialize_pieces(state["pieces"])
    current_turn = String.to_atom(state["current_turn"] || "white")
    ep           = parse_ep(state["en_passant_target"])

    if has_legal_move?(pieces, current_turn, ep) do
      :ongoing
    else
      if in_check?(pieces, current_turn) do
        {:finished, if(current_turn == :white, do: "black_wins", else: "white_wins")}
      else
        {:finished, "draw"}
      end
    end
  end

  # ── Board manipulation ─────────────────────────────────────────────────────

  # Apply a move to a pieces map, handling en passant and promotion.
  defp apply_pieces(pieces, piece, color, from_sq, to_sq, ep) do
    {_old, pieces} = Map.pop(pieces, from_sq)

    # En passant: remove the captured pawn behind the target square.
    pieces =
      if piece == :pawn and ep == to_sq do
        {tc, tr} = to_sq
        dir = if color == :white, do: 1, else: -1
        Map.delete(pieces, {tc, tr - dir})
      else
        pieces
      end

    # Pawn promotion → auto-queen.
    promoted =
      case {piece, color, to_sq} do
        {:pawn, :white, {_, 8}} -> :queen
        {:pawn, :black, {_, 1}} -> :queen
        _                       -> piece
      end

    Map.put(pieces, to_sq, {promoted, color})
  end

  # ── Check / legal-move logic ───────────────────────────────────────────────

  # Is `color`'s king attacked by any opponent piece?
  defp in_check?(pieces, color) do
    king_sq = find_king(pieces, color)
    if is_nil(king_sq) do
      true  # king missing = already lost (shouldn't happen in normal play)
    else
      opp = opponent(color)
      Enum.any?(pieces, fn {sq, {piece, c}} ->
        c == opp and attacks_square?(piece, opp, sq, king_sq, pieces)
      end)
    end
  end

  defp find_king(pieces, color) do
    case Enum.find(pieces, fn {_, {p, c}} -> p == :king and c == color end) do
      {sq, _} -> sq
      nil     -> nil
    end
  end

  # Does `color` have at least one fully legal move?
  defp has_legal_move?(pieces, color, ep) do
    pieces
    |> Enum.filter(fn {_, {_, c}} -> c == color end)
    |> Enum.any?(fn {from_sq, {piece, _}} ->
      candidate_destinations(piece, color, from_sq, pieces, ep)
      |> Enum.any?(fn to_sq ->
        dest_valid?(pieces, to_sq, color) and
          can_move?(piece, color, from_sq, to_sq, pieces, ep) and
          not in_check?(apply_pieces(pieces, piece, color, from_sq, to_sq, ep), color)
      end)
    end)
  end

  # ── Move legality helpers ──────────────────────────────────────────────────

  defp get_piece(pieces, sq) do
    case Map.get(pieces, sq) do
      nil   -> {:error, :empty}
      piece -> {:ok, piece}
    end
  end

  defp dest_valid?(pieces, to_sq, color) do
    case Map.get(pieces, to_sq) do
      nil           -> true
      {_, ^color}   -> false
      _             -> true
    end
  end

  defp can_move?(:pawn, color, {fc, fr}, {tc, tr}, pieces, ep) do
    dir       = if color == :white, do: 1, else: -1
    start_row = if color == :white, do: 2, else: 7

    cond do
      # Forward single step — destination must be empty.
      fc == tc and tr == fr + dir and is_nil(Map.get(pieces, {tc, tr})) ->
        true

      # Forward double step from starting rank — both squares empty.
      fc == tc and fr == start_row and tr == fr + 2 * dir and
          is_nil(Map.get(pieces, {tc, tr})) and
          is_nil(Map.get(pieces, {fc, fr + dir})) ->
        true

      # Diagonal capture — enemy piece present OR en passant square.
      abs(tc - fc) == 1 and tr == fr + dir ->
        case Map.get(pieces, {tc, tr}) do
          {_, cap_c} when cap_c != color -> true
          nil when not is_nil(ep) and ep == {tc, tr} -> true
          _ -> false
        end

      true -> false
    end
  end

  defp can_move?(:rook, _c, {fc, fr}, {tc, tr}, pieces, _ep),
    do: (fc == tc or fr == tr) and path_clear?(pieces, {fc, fr}, {tc, tr})

  defp can_move?(:bishop, _c, {fc, fr}, {tc, tr}, pieces, _ep),
    do: abs(tc - fc) == abs(tr - fr) and abs(tc - fc) > 0 and path_clear?(pieces, {fc, fr}, {tc, tr})

  defp can_move?(:queen, c, from, to, pieces, ep),
    do: can_move?(:rook, c, from, to, pieces, ep) or can_move?(:bishop, c, from, to, pieces, ep)

  defp can_move?(:knight, _c, {fc, fr}, {tc, tr}, _pieces, _ep),
    do: {abs(tc - fc), abs(tr - fr)} in [{1, 2}, {2, 1}]

  defp can_move?(:king, _c, {fc, fr}, {tc, tr}, _pieces, _ep),
    do: abs(tc - fc) <= 1 and abs(tr - fr) <= 1 and {tc, tr} != {fc, fr}

  # Piece attack check (used for check detection — same as can_move? except
  # pawns attack diagonally only, regardless of whether a piece is there).
  defp attacks_square?(:pawn, color, {fc, fr}, {tc, tr}, _pieces) do
    dir = if color == :white, do: 1, else: -1
    abs(tc - fc) == 1 and tr == fr + dir
  end
  defp attacks_square?(:knight, c, from, to, pieces), do: can_move?(:knight, c, from, to, pieces, nil)
  defp attacks_square?(:bishop, c, from, to, pieces), do: can_move?(:bishop, c, from, to, pieces, nil)
  defp attacks_square?(:rook,   c, from, to, pieces), do: can_move?(:rook,   c, from, to, pieces, nil)
  defp attacks_square?(:queen,  c, from, to, pieces), do: can_move?(:queen,  c, from, to, pieces, nil)
  defp attacks_square?(:king,   c, from, to, pieces), do: can_move?(:king,   c, from, to, pieces, nil)

  # ── Candidate destination generator ───────────────────────────────────────
  # Used to enumerate possible moves without checking legality first.
  # Filters to board boundaries only (1-8 for both axes).

  defp candidate_destinations(:pawn, color, {fc, fr}, _pieces, ep) do
    dir       = if color == :white, do: 1, else: -1
    start_row = if color == :white, do: 2, else: 7
    base = [{fc, fr + dir}, {fc - 1, fr + dir}, {fc + 1, fr + dir}]
    base = if fr == start_row, do: [{fc, fr + 2 * dir} | base], else: base
    base = if ep, do: [ep | base], else: base
    Enum.filter(base, &in_bounds?/1)
  end

  defp candidate_destinations(:knight, _c, {fc, fr}, _pieces, _ep) do
    for dc <- [-2, -1, 1, 2], dr <- [-2, -1, 1, 2], abs(dc) != abs(dr),
        sq = {fc + dc, fr + dr}, in_bounds?(sq), do: sq
  end

  defp candidate_destinations(:bishop, _c, {fc, fr}, _pieces, _ep) do
    for d <- 1..7, sc <- [-1, 1], sr <- [-1, 1],
        sq = {fc + d * sc, fr + d * sr}, in_bounds?(sq), do: sq
  end

  defp candidate_destinations(:rook, _c, {fc, fr}, _pieces, _ep) do
    (for d <- 1..7, sq <- [{fc + d, fr}, {fc - d, fr}, {fc, fr + d}, {fc, fr - d}],
         in_bounds?(sq), do: sq)
    |> Enum.uniq()
  end

  defp candidate_destinations(:queen, c, pos, pieces, ep),
    do: candidate_destinations(:rook, c, pos, pieces, ep) ++
        candidate_destinations(:bishop, c, pos, pieces, ep)

  defp candidate_destinations(:king, _c, {fc, fr}, _pieces, _ep) do
    for dc <- [-1, 0, 1], dr <- [-1, 0, 1], {dc, dr} != {0, 0},
        sq = {fc + dc, fr + dr}, in_bounds?(sq), do: sq
  end

  # ── Utilities ──────────────────────────────────────────────────────────────

  defp in_bounds?({c, r}), do: c >= 1 and c <= 8 and r >= 1 and r <= 8

  defp opponent(:white), do: :black
  defp opponent(:black), do: :white

  defp parse_sq([col, row]),                    do: {col, row}
  defp parse_sq(%{"col" => col, "row" => row}), do: {col, row}

  defp parse_ep(nil),                              do: nil
  defp parse_ep([col, row]),                       do: {col, row}
  defp parse_ep(%{"col" => col, "row" => row}),    do: {col, row}

  defp serialize_ep(nil),        do: nil
  defp serialize_ep({col, row}), do: [col, row]

  defp path_clear?(pieces, {fc, fr}, {tc, tr}) do
    dc    = sign(tc - fc)
    dr    = sign(tr - fr)
    steps = max(abs(tc - fc), abs(tr - fr)) - 1
    if steps <= 0 do
      true
    else
      Enum.reduce_while(1..steps, true, fn i, _ ->
        if Map.has_key?(pieces, {fc + i * dc, fr + i * dr}),
          do: {:halt, false}, else: {:cont, true}
      end)
    end
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_), do: -1
end

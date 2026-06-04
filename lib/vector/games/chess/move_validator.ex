defmodule Vector.Games.Chess.MoveValidator do
  @moduledoc """
  Server-side chess move validation.

  Implements full legal-move rules:
  - Piece movement geometry (all six types)
  - King safety: moves that leave own king in check are rejected
  - Checkmate / stalemate detection
  - En passant capture
  - Pawn promotion (auto-queen)
  - Castling (kingside and queenside, both colours)
  - Castling rights tracking (king or rook move → rights revoked)
  """

  alias Vector.Games.Chess.Board

  # ── Castling geometry ──────────────────────────────────────────────────────
  # For each colour and side, defines the required starting positions,
  # destination squares, empty-path squares, and king-pass squares.

  @castle %{
    white: %{
      kingside: %{
        king_from: {5, 1}, king_to: {7, 1},
        rook_from: {8, 1}, rook_to: {6, 1},
        rights_key: "white_king",
        empty: [{6, 1}, {7, 1}],
        pass:  [{6, 1}]               # squares king must not be attacked on
      },
      queenside: %{
        king_from: {5, 1}, king_to: {3, 1},
        rook_from: {1, 1}, rook_to: {4, 1},
        rights_key: "white_queen",
        empty: [{2, 1}, {3, 1}, {4, 1}],
        pass:  [{4, 1}, {3, 1}]
      }
    },
    black: %{
      kingside: %{
        king_from: {5, 8}, king_to: {7, 8},
        rook_from: {8, 8}, rook_to: {6, 8},
        rights_key: "black_king",
        empty: [{6, 8}, {7, 8}],
        pass:  [{6, 8}]
      },
      queenside: %{
        king_from: {5, 8}, king_to: {3, 8},
        rook_from: {1, 8}, rook_to: {4, 8},
        rights_key: "black_queen",
        empty: [{2, 8}, {3, 8}, {4, 8}],
        pass:  [{4, 8}, {3, 8}]
      }
    }
  }

  # ── Public API ─────────────────────────────────────────────────────────────

  def valid_move?(state, move, player_color) do
    %{"from" => from, "to" => to} = move
    pieces   = Board.deserialize_pieces(state["pieces"])
    from_sq  = parse_sq(from)
    to_sq    = parse_sq(to)
    ep       = parse_ep(state["en_passant_target"])
    castling = state["castling_rights"] || %{}

    with {:ok, {piece, ^player_color}} <- get_piece(pieces, from_sq),
         true <- dest_valid?(pieces, to_sq, player_color),
         true <- can_move?(piece, player_color, from_sq, to_sq, pieces, ep, castling) do
      pieces_after = apply_pieces(pieces, piece, player_color, from_sq, to_sq, ep, castling)
      not in_check?(pieces_after, player_color)
    else
      _ -> false
    end
  end

  def apply_move(state, move) do
    %{"from" => from, "to" => to} = move
    pieces       = Board.deserialize_pieces(state["pieces"])
    from_sq      = parse_sq(from)
    to_sq        = parse_sq(to)
    player_color = String.to_atom(state["current_turn"])
    ep           = parse_ep(state["en_passant_target"])
    castling     = state["castling_rights"] || %{}

    {piece, _}   = Map.get(pieces, from_sq)
    pieces_after = apply_pieces(pieces, piece, player_color, from_sq, to_sq, ep, castling)

    # Update castling rights: king or rook move revokes rights;
    # capturing an opponent's starting rook also revokes their right.
    new_castling =
      castling
      |> revoke_for_mover(piece, player_color, from_sq)
      |> revoke_for_captured_rook(pieces, to_sq)

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
    check_val  = if in_check?(pieces_after, next_color), do: next_turn, else: nil

    updated =
      state
      |> Map.put("pieces", Board.serialize_pieces(pieces_after))
      |> Map.put("current_turn", next_turn)
      |> Map.put("en_passant_target", serialize_ep(new_ep))
      |> Map.put("castling_rights", new_castling)
      |> Map.put("in_check", check_val)

    {:ok, updated}
  end

  def check_game_over(state) do
    pieces   = Board.deserialize_pieces(state["pieces"])
    current  = String.to_atom(state["current_turn"] || "white")
    ep       = parse_ep(state["en_passant_target"])
    castling = state["castling_rights"] || %{}

    if has_legal_move?(pieces, current, ep, castling) do
      :ongoing
    else
      if in_check?(pieces, current) do
        {:finished, if(current == :white, do: "black_wins", else: "white_wins")}
      else
        {:finished, "draw"}
      end
    end
  end

  # ── Board manipulation ─────────────────────────────────────────────────────

  defp apply_pieces(pieces, piece, color, from_sq, to_sq, ep, _castling) do
    {_old, pieces} = Map.pop(pieces, from_sq)

    # En passant: remove the captured pawn
    pieces =
      if piece == :pawn and ep == to_sq do
        {tc, tr} = to_sq
        dir = if color == :white, do: 1, else: -1
        Map.delete(pieces, {tc, tr - dir})
      else
        pieces
      end

    # Pawn promotion → auto-queen
    promoted =
      case {piece, color, to_sq} do
        {:pawn, :white, {_, 8}} -> :queen
        {:pawn, :black, {_, 1}} -> :queen
        _ -> piece
      end

    pieces = Map.put(pieces, to_sq, {promoted, color})

    # Castling: also move the rook
    if is_castling?(piece, from_sq, to_sq) do
      castle_info = find_castle_info(color, to_sq)
      if castle_info do
        pieces
        |> Map.delete(castle_info.rook_from)
        |> Map.put(castle_info.rook_to, {:rook, color})
      else
        pieces
      end
    else
      pieces
    end
  end

  # ── Castling helpers ───────────────────────────────────────────────────────

  defp is_castling?(:king, {fc, _fr}, {tc, _tr}), do: abs(tc - fc) == 2
  defp is_castling?(_, _, _), do: false

  defp find_castle_info(color, to_sq) do
    sides = @castle[color]
    Enum.find_value(sides, fn {_side, info} ->
      if info.king_to == to_sq, do: info
    end)
  end

  defp castling_valid?(color, to_sq, pieces, castling) do
    castle_info = find_castle_info(color, to_sq)
    if is_nil(castle_info) do
      false
    else
      castling[castle_info.rights_key] == true and
        Map.get(pieces, castle_info.king_from) == {:king, color} and
        Map.get(pieces, castle_info.rook_from) == {:rook, color} and
        Enum.all?(castle_info.empty, &is_nil(Map.get(pieces, &1))) and
        not in_check?(pieces, color) and
        Enum.all?(castle_info.pass, fn sq ->
          temp = pieces |> Map.delete(castle_info.king_from) |> Map.put(sq, {:king, color})
          not in_check?(temp, color)
        end)
    end
  end

  defp revoke_for_mover(castling, :king, color, _from_sq) do
    Map.merge(castling, %{
      "#{color}_king"  => false,
      "#{color}_queen" => false
    })
  end

  defp revoke_for_mover(castling, :rook, color, from_sq) do
    row = if color == :white, do: 1, else: 8
    case from_sq do
      {8, ^row} -> Map.put(castling, "#{color}_king", false)
      {1, ^row} -> Map.put(castling, "#{color}_queen", false)
      _         -> castling
    end
  end

  defp revoke_for_mover(castling, _piece, _color, _from_sq), do: castling

  defp revoke_for_captured_rook(castling, pieces, to_sq) do
    case Map.get(pieces, to_sq) do
      {:rook, opp_color} ->
        opp_row = if opp_color == :white, do: 1, else: 8
        case to_sq do
          {8, ^opp_row} -> Map.put(castling, "#{opp_color}_king", false)
          {1, ^opp_row} -> Map.put(castling, "#{opp_color}_queen", false)
          _             -> castling
        end
      _ -> castling
    end
  end

  # ── Check / legal-move logic ───────────────────────────────────────────────

  defp in_check?(pieces, color) do
    king_sq = find_king(pieces, color)
    if is_nil(king_sq) do
      true
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

  defp has_legal_move?(pieces, color, ep, castling) do
    # Regular moves
    has_regular =
      pieces
      |> Enum.filter(fn {_, {_, c}} -> c == color end)
      |> Enum.any?(fn {from_sq, {piece, _}} ->
        candidate_destinations(piece, color, from_sq, pieces, ep, castling)
        |> Enum.any?(fn to_sq ->
          dest_valid?(pieces, to_sq, color) and
            can_move?(piece, color, from_sq, to_sq, pieces, ep, castling) and
            not in_check?(apply_pieces(pieces, piece, color, from_sq, to_sq, ep, castling), color)
        end)
      end)

    has_regular or can_castle_any?(color, pieces, castling)
  end

  defp can_castle_any?(color, pieces, castling) do
    sides = Map.get(@castle, color, %{})
    Enum.any?(sides, fn {_side, info} ->
      castling_valid?(color, info.king_to, pieces, castling)
    end)
  end

  # ── Move legality ──────────────────────────────────────────────────────────

  defp get_piece(pieces, sq) do
    case Map.get(pieces, sq) do
      nil   -> {:error, :empty}
      piece -> {:ok, piece}
    end
  end

  defp dest_valid?(pieces, to_sq, color) do
    case Map.get(pieces, to_sq) do
      nil         -> true
      {_, ^color} -> false
      _           -> true
    end
  end

  defp can_move?(piece, color, from, to, pieces, ep, castling \\ %{})

  defp can_move?(:pawn, color, {fc, fr}, {tc, tr}, pieces, ep, _castling) do
    dir       = if color == :white, do: 1, else: -1
    start_row = if color == :white, do: 2, else: 7

    cond do
      fc == tc and tr == fr + dir and is_nil(Map.get(pieces, {tc, tr})) ->
        true
      fc == tc and fr == start_row and tr == fr + 2 * dir and
          is_nil(Map.get(pieces, {tc, tr})) and
          is_nil(Map.get(pieces, {fc, fr + dir})) ->
        true
      abs(tc - fc) == 1 and tr == fr + dir ->
        case Map.get(pieces, {tc, tr}) do
          {_, cap_c} when cap_c != color -> true
          nil when not is_nil(ep) and ep == {tc, tr} -> true
          _ -> false
        end
      true -> false
    end
  end

  defp can_move?(:rook, _c, {fc, fr}, {tc, tr}, pieces, _ep, _castling),
    do: (fc == tc or fr == tr) and path_clear?(pieces, {fc, fr}, {tc, tr})

  defp can_move?(:bishop, _c, {fc, fr}, {tc, tr}, pieces, _ep, _castling),
    do: abs(tc - fc) == abs(tr - fr) and abs(tc - fc) > 0 and
        path_clear?(pieces, {fc, fr}, {tc, tr})

  defp can_move?(:queen, c, from, to, pieces, ep, castling),
    do: can_move?(:rook, c, from, to, pieces, ep, castling) or
        can_move?(:bishop, c, from, to, pieces, ep, castling)

  defp can_move?(:knight, _c, {fc, fr}, {tc, tr}, _pieces, _ep, _castling),
    do: {abs(tc - fc), abs(tr - fr)} in [{1, 2}, {2, 1}]

  defp can_move?(:king, color, from, to, pieces, _ep, castling) do
    {fc, fr} = from; {tc, tr} = to
    if abs(tc - fc) <= 1 and abs(tr - fr) <= 1 and {tc, tr} != {fc, fr} do
      true
    else
      # 2-square move = castling attempt
      is_castling?(:king, from, to) and castling_valid?(color, to, pieces, castling)
    end
  end

  # Attack squares ignore castling (pawns attack diagonally only)
  defp attacks_square?(:pawn, color, {fc, fr}, {tc, tr}, _pieces) do
    dir = if color == :white, do: 1, else: -1
    abs(tc - fc) == 1 and tr == fr + dir
  end
  defp attacks_square?(:knight, c, f, t, p), do: can_move?(:knight, c, f, t, p, nil)
  defp attacks_square?(:bishop, c, f, t, p), do: can_move?(:bishop, c, f, t, p, nil)
  defp attacks_square?(:rook,   c, f, t, p), do: can_move?(:rook,   c, f, t, p, nil)
  defp attacks_square?(:queen,  c, f, t, p), do: can_move?(:queen,  c, f, t, p, nil)
  defp attacks_square?(:king,   c, f, t, p), do: can_move?(:king,   c, f, t, p, nil)

  # ── Candidate destination generator ───────────────────────────────────────

  defp candidate_destinations(:pawn, color, {fc, fr}, _pieces, ep, _castling) do
    dir       = if color == :white, do: 1, else: -1
    start_row = if color == :white, do: 2, else: 7
    base = [{fc, fr + dir}, {fc - 1, fr + dir}, {fc + 1, fr + dir}]
    base = if fr == start_row, do: [{fc, fr + 2 * dir} | base], else: base
    base = if ep, do: [ep | base], else: base
    Enum.filter(base, &in_bounds?/1)
  end

  defp candidate_destinations(:knight, _c, {fc, fr}, _pieces, _ep, _castling) do
    for dc <- [-2, -1, 1, 2], dr <- [-2, -1, 1, 2], abs(dc) != abs(dr),
        sq = {fc + dc, fr + dr}, in_bounds?(sq), do: sq
  end

  defp candidate_destinations(:bishop, _c, {fc, fr}, _pieces, _ep, _castling) do
    for d <- 1..7, sc <- [-1, 1], sr <- [-1, 1],
        sq = {fc + d * sc, fr + d * sr}, in_bounds?(sq), do: sq
  end

  defp candidate_destinations(:rook, _c, {fc, fr}, _pieces, _ep, _castling) do
    (for d <- 1..7, sq <- [{fc + d, fr}, {fc - d, fr}, {fc, fr + d}, {fc, fr - d}],
         in_bounds?(sq), do: sq)
    |> Enum.uniq()
  end

  defp candidate_destinations(:queen, c, pos, pieces, ep, castling),
    do: (candidate_destinations(:rook, c, pos, pieces, ep, castling) ++
         candidate_destinations(:bishop, c, pos, pieces, ep, castling))
        |> Enum.uniq()

  defp candidate_destinations(:king, color, {fc, fr}, _pieces, _ep, castling) do
    # Normal king moves
    normal = for dc <- [-1, 0, 1], dr <- [-1, 0, 1], {dc, dr} != {0, 0},
                 sq = {fc + dc, fr + dr}, in_bounds?(sq), do: sq

    # Castling target squares (actual legality checked in can_move?)
    castle_targets =
      Map.get(@castle, color, %{})
      |> Enum.filter(fn {_side, info} ->
        castling[info.rights_key] == true and info.king_from == {fc, fr}
      end)
      |> Enum.map(fn {_side, info} -> info.king_to end)

    (normal ++ castle_targets) |> Enum.uniq()
  end

  # ── Utilities ──────────────────────────────────────────────────────────────

  defp in_bounds?({c, r}), do: c >= 1 and c <= 8 and r >= 1 and r <= 8

  defp opponent(:white), do: :black
  defp opponent(:black), do: :white

  defp parse_sq([col, row]),                    do: {col, row}
  defp parse_sq(%{"col" => col, "row" => row}), do: {col, row}

  defp parse_ep(nil),                           do: nil
  defp parse_ep([col, row]),                    do: {col, row}
  defp parse_ep(%{"col" => col, "row" => row}), do: {col, row}

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

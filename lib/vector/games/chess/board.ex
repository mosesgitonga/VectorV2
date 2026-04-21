defmodule Vector.Games.Chess.Board do
  @moduledoc """
  Chess board representation and initial state.
  Board is a map of {col, row} => {piece, color}.
  Cols: a-h (1-8), Rows: 1-8.
  """

  @initial_pieces %{
    # White pieces
    {1, 1} => {:rook, :white},   {2, 1} => {:knight, :white},
    {3, 1} => {:bishop, :white}, {4, 1} => {:queen, :white},
    {5, 1} => {:king, :white},   {6, 1} => {:bishop, :white},
    {7, 1} => {:knight, :white}, {8, 1} => {:rook, :white},
    {1, 2} => {:pawn, :white},   {2, 2} => {:pawn, :white},
    {3, 2} => {:pawn, :white},   {4, 2} => {:pawn, :white},
    {5, 2} => {:pawn, :white},   {6, 2} => {:pawn, :white},
    {7, 2} => {:pawn, :white},   {8, 2} => {:pawn, :white},
    # Black pieces
    {1, 8} => {:rook, :black},   {2, 8} => {:knight, :black},
    {3, 8} => {:bishop, :black}, {4, 8} => {:queen, :black},
    {5, 8} => {:king, :black},   {6, 8} => {:bishop, :black},
    {7, 8} => {:knight, :black}, {8, 8} => {:rook, :black},
    {1, 7} => {:pawn, :black},   {2, 7} => {:pawn, :black},
    {3, 7} => {:pawn, :black},   {4, 7} => {:pawn, :black},
    {5, 7} => {:pawn, :black},   {6, 7} => {:pawn, :black},
    {7, 7} => {:pawn, :black},   {8, 7} => {:pawn, :black}
  }

  def initial_state do
    %{
      pieces: serialize_pieces(@initial_pieces),
      current_turn: "white",
      castling_rights: %{
        white_king: true, white_queen: true,
        black_king: true, black_queen: true
      },
      en_passant_target: nil,
      half_move_clock: 0,
      full_move_number: 1,
      status: "active"
    }
  end

  def serialize_pieces(pieces) do
    Enum.map(pieces, fn {{col, row}, {piece, color}} ->
      %{"col" => col, "row" => row, "piece" => to_string(piece), "color" => to_string(color)}
    end)
  end

  def deserialize_pieces(pieces_list) do
    Enum.reduce(pieces_list, %{}, fn %{"col" => c, "row" => r, "piece" => p, "color" => color}, acc ->
      Map.put(acc, {c, r}, {String.to_atom(p), String.to_atom(color)})
    end)
  end
end

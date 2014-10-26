class GamesController < ApplicationController
  include ApplicationHelper

  def create
    @error = nil
    # Check game source password. (If invalid, render error.)
    # Any trusted kifu provider can post kifu (for example 81Dojo) with its unique password.
    unless (params[:game_source_pass] && game_source = GameSource.find_by(pass: params[:game_source_pass]))
      @error = 'No proper game source specified.'
      return
    end
    # Check handicap code. (If invalid, render error.) 1: even 2: lance-handicap 3: 4: 5: ...... 9: 8-piece-handicap
    unless (params[:handicap_id] && Handicap.find(params[:handicap_id]))
      @error = 'No proper handicap specified.'
      return
    end

    # parse moves from the continuous CSA move string
    csa_moves = []
    rs = params[:csa].gsub %r{[\+\-]\d{4}\w{2}} do |s|
      csa_moves << s
      ""
    end
    if !rs.empty?
      if (rs == '%TORYO')
        csa_moves << rs
      else
        @error = 'Invalid moves.'
        return
      end
    end
    if csa_moves.empty?
      @error = 'No moves specified.'
      return
    end
    @board = Board.new
    @board.initial(params[:handicap_id].to_i)

    sfens = [] # sfen for each move, which is used to identify/register Position model.
    @csa_positions = []  # csa position for each move, which is shown in the view.
    positions = [] # Position models
    rt = nil

    sfens << @board.to_sfen
    @csa_positions << @board.to_s
    csa_moves.each do |csa_move|
      rt = @board.handle_one_move(csa_move)
      unless (rt == :normal || rt == :toryo)
        @error = 'Illegal move'
        return
      end
      sfens << @board.to_sfen
      @csa_positions << @board.to_s
    end

    # If the kifu is OK, then update database
    strategy_id = nil
    @game = Game.new(params.permit(:black_name, :white_name, :date, :csa, :result, :handicap_id, :native_kid))
    @game.game_source = game_source
    begin
      @game.save
    rescue
      @error = 'Duplicate Kifu'
      return
    end
    for i in 0..(sfens.length - 1) do
      unless (position = Position.find_by(sfen: sfens[i]))
        position = Position.create(:sfen => sfens[i], :csa => @csa_positions[i], :handicap_id => params[:handicap_id])
      end
      positions << position
    end
    position_already = Hash::new(false)
    move_already = Hash::new(false)
    begin
      for i in 0..(positions.length - 1) do
        unless (i >= positions.length - 1)
          unless (move = Move.find_by(prev_position_id: positions[i].id, next_position_id: positions[i+1].id))
            move = Move.new(:prev_position_id => positions[i].id, :next_position_id => positions[i+1].id, :csa => csa_moves[i])
            move.analyze
          end
          unless move_already[move.id]
            if (@game.game_source.category == 1)
              move.stat1_total += 1
            elsif (@game.game_source.category == 2)
              move.stat2_total += 1
            end
            move.save
          end
          move_already[move.id] = true
        end

        unless position_already[positions[i].id]
          if (positions[i].strategy_id)
            strategy_id = positions[i].strategy_id
          else
            positions[i].strategy_id = strategy_id
          end
          if (@game.game_source.category == 1)  # Official professional kifu
            if (@game.result == 0) 
              positions[i].stat1_black += 1
            elsif (@game.result == 1)
              positions[i].stat1_white += 1
            elsif (@game.result == 2)
              positions[i].stat1_draw += 1
            end
          elsif (@game.game_source.category == 2)  # Amateur online games
            if (@game.result == 0) 
              positions[i].stat2_black += 1
            elsif (@game.result == 1)
              positions[i].stat2_white += 1
            elsif (@game.result == 2)
              positions[i].stat2_draw += 1
            end
          end
          positions[i].games << @game
          positions[i].save

          appearance = Appearance.last
          appearance.num = i
          appearance.next_move = move
          appearance.save
        end
        position_already[positions[i].id] = true
      end
    rescue
      @game.destroy
      @error = 'Database error.'
      return
    end

  end

end

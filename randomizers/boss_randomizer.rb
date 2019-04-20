
module BossRandomizer
  def randomize_bosses
    spoiler_log.puts "Shuffling bosses:"
    
    dos_randomize_final_boss()
    
    boss_entities = []
    game.each_room do |room|
      boss_entities += room.entities.select{|e| e.is_boss? && RANDOMIZABLE_BOSS_IDS.include?(e.subtype)}
    end
    
    remove_boss_cutscenes()
    
    if GAME == "dos"
      # Turn the throne room Dario entity into Aguni so the boss randomizer logic works.
      throne_room_dario = game.areas[0].sectors[9].rooms[1].entities[6]
      throne_room_dario.subtype = 0x70
    end
    
    # Determine unique boss rooms.
    boss_rooms_for_each_boss = {}
    boss_entities.each do |boss_entity|
      boss_rooms_for_each_boss[boss_entity.subtype] ||= []
      boss_rooms_for_each_boss[boss_entity.subtype] << boss_entity.room
      boss_rooms_for_each_boss[boss_entity.subtype].uniq!
    end
    # Figure out what bosses can be placed in what rooms.
    boss_swaps_that_work = {}
    boss_rooms_for_each_boss.each do |old_boss_id, boss_rooms|
      old_boss = game.enemy_dnas[old_boss_id]
      
      RANDOMIZABLE_BOSS_IDS.each do |new_boss_id|
        new_boss = game.enemy_dnas[new_boss_id]
        
        all_rooms_work = boss_rooms.all? do |boss_room|
          boss_entity = boss_room.entities.select{|e| e.is_boss? && e.subtype == old_boss_id}.first
          case GAME
          when "dos"
            dos_check_boss_works_in_room(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
          when "por"
            por_check_boss_works_in_room(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
          when "ooe"
            ooe_check_boss_works_in_room(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
          end
        end
        
        if all_rooms_work
          boss_swaps_that_work[old_boss_id] ||= []
          boss_swaps_that_work[old_boss_id] << new_boss_id
        end
      end
    end
    # Limit to swaps that work both ways.
    boss_swaps_that_work.each do |old_boss_id, new_boss_ids|
      new_boss_ids.select! do |new_boss_id|
        next if boss_swaps_that_work[new_boss_id].nil?
        boss_swaps_that_work[new_boss_id].include?(old_boss_id)
      end
    end
    boss_swaps_that_work.each do |old_boss_id, valid_new_boss_ids|
      old_boss = game.enemy_dnas[old_boss_id]
      puts "Boss %02X (#{old_boss.name}) can be swapped with:" % [old_boss_id]
      valid_new_boss_ids.each do |new_boss_id|
        new_boss = game.enemy_dnas[new_boss_id]
        puts "  Boss %02X (#{new_boss.name})" % [new_boss_id]
      end
    end
    
    remaining_boss_ids = RANDOMIZABLE_BOSS_IDS.dup
    queued_dna_changes = Hash.new{|h, k| h[k] = {}}
    already_randomized_bosses = {}
    if GAME == "dos"
      @original_boss_seals = {}
      (0..0x11).each do |boss_index|
        seal_index = game.fs.read(MAGIC_SEAL_FOR_BOSS_LIST_START+boss_index*4, 4).unpack("V").first
        @original_boss_seals[boss_index] = seal_index
      end
    end
    
    boss_entities.shuffle(random: rng).each do |boss_entity|
      old_boss_id = boss_entity.subtype
      old_boss = game.enemy_dnas[old_boss_id]
      
      already_randomized_new_boss_id = already_randomized_bosses[old_boss_id]
      if already_randomized_new_boss_id
        new_boss_id = already_randomized_new_boss_id
      else
        possible_boss_ids_for_this_boss = boss_swaps_that_work[old_boss_id] & remaining_boss_ids
        if possible_boss_ids_for_this_boss.empty?
          # Nothing this could possibly randomize into and work correctly. Skip.
          puts "BOSS %02X FAILED!" % old_boss_id
          next
        end
        
        new_boss_id = possible_boss_ids_for_this_boss.sample(random: rng)
      end
      new_boss = game.enemy_dnas[new_boss_id]
      
      result = case GAME
      when "dos"
        dos_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
      when "por"
        por_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
      when "ooe"
        ooe_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
      end
      if result == :skip
        next
      end
      
      spoiler_str = "  Replacing boss %02X (#{old_boss.name}) with boss %02X (#{new_boss.name})" % [old_boss_id, new_boss_id]
      puts spoiler_str
      spoiler_log.puts spoiler_str
      
      boss_entity.subtype = new_boss_id
      remaining_boss_ids.delete(new_boss_id)
      remaining_boss_ids.delete(old_boss_id)
      
      boss_entity.write_to_rom()
      
      already_randomized_bosses[old_boss_id] = new_boss_id
      already_randomized_bosses[new_boss_id] = old_boss_id
      
      update_boss_doors(old_boss_id, new_boss_id, boss_entity)
      
      # Give the new boss the old boss's soul so progression still works.
      queued_dna_changes[new_boss_id]["Soul"] = old_boss["Soul"]
      if old_boss["Soul"] == 0xFF
        # Some bosses such as Flying Armor won't open the boss doors until the player gets their soul drop.
        # So we have to make sure no bosses have no soul drop (FF).
        non_progression_souls = SKILL_GLOBAL_ID_RANGE.to_a - checker.all_progression_pickups - NONRANDOMIZABLE_PICKUP_GLOBAL_IDS
        queued_dna_changes[new_boss_id]["Soul"] = non_progression_souls.sample(random: rng) - SKILL_GLOBAL_ID_RANGE.begin
      end
      
      # Make the new boss have the stats of the old boss so it fits in at this point in the game.
      queued_dna_changes[new_boss_id]["HP"]               = old_boss["HP"]
      queued_dna_changes[new_boss_id]["MP"]               = old_boss["MP"]
      queued_dna_changes[new_boss_id]["SP"]               = old_boss["SP"]
      queued_dna_changes[new_boss_id]["AP"]               = old_boss["AP"]
      queued_dna_changes[new_boss_id]["EXP"]              = old_boss["EXP"]
      queued_dna_changes[new_boss_id]["Attack"]           = old_boss["Attack"]
      queued_dna_changes[new_boss_id]["Defense"]          = old_boss["Defense"]
      queued_dna_changes[new_boss_id]["Physical Defense"] = old_boss["Physical Defense"]
      queued_dna_changes[new_boss_id]["Magical Defense"]  = old_boss["Magical Defense"]
      
      if new_boss_id == 0x87 # Fake Trevor
        [0x88, 0x89].each do |other_boss_id| # Fake Grant and Sypha
          queued_dna_changes[other_boss_id]["HP"]               = old_boss["HP"]
          queued_dna_changes[other_boss_id]["MP"]               = old_boss["MP"]
          queued_dna_changes[other_boss_id]["SP"]               = old_boss["SP"]
          queued_dna_changes[other_boss_id]["AP"]               = old_boss["AP"]
          queued_dna_changes[other_boss_id]["EXP"]              = old_boss["EXP"]
          queued_dna_changes[other_boss_id]["Attack"]           = old_boss["Attack"]
          queued_dna_changes[other_boss_id]["Defense"]          = old_boss["Defense"]
          queued_dna_changes[other_boss_id]["Physical Defense"] = old_boss["Physical Defense"]
          queued_dna_changes[other_boss_id]["Magical Defense"]  = old_boss["Magical Defense"]
        end
      end
      
      if old_boss.name == "Wallman"
        # Don't copy Wallman's 9999 HP, use a more reasonable value instead.
        queued_dna_changes[new_boss_id]["HP"] = 4000
      end
      if new_boss.name == "Wallman"
        # Make sure Wallman always has 9999 HP.
        queued_dna_changes[new_boss_id]["HP"] = 9999
      end
    end
    
    queued_dna_changes.each do |boss_id, changes|
      boss = game.enemy_dnas[boss_id]
      
      changes.each do |attribute_name, new_value|
        boss[attribute_name] = new_value
      end
      
      boss.write_to_rom()
    end
    
    spoiler_log.puts "All bosses randomized successfully."
  end
  
  def dos_check_boss_works_in_room(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    case new_boss.name
    when "Balore"
      coll = RoomCollision.new(boss_entity.room, game.fs)
      (0x40..0xC0).each do |x|
        # If the floor is 2 tiles high instead of 1, the player won't have room to crouch under Balore' huge laser.
        if coll[x,0xA0].is_solid?
          return false
        end
      end
    when "Puppet Master"
      # If Puppet Master is in a room less than 2 screens wide he can teleport the player out of bounds.
      if boss_entity.room.width < 2
        return false
      end
    end
    
    if old_boss.name == "Rahab" && ["Malphas", "Dmitrii", "Dario", "Gergoth", "Zephyr", "Paranoia", "Abaddon"].include?(new_boss.name)
      # These bosses will fall to below the water level in Rahab's room, which is a problem if the player doesn't have Rahab yet.
      return false
    end
    
    return true
  end
  
  def por_check_boss_works_in_room(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    return true
  end
  
  def ooe_check_boss_works_in_room(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    case new_boss.name
    when "Maneater"
      # Maneater needs a wide room or his boss orb will be stuck inside the wall.
      if boss_entity.room.width < 2
        return false
      end
    when "Blackmore"
      # Blackmore needs a wide room.
      if boss_entity.room.width < 2
        return false
      end
    end
    
    return true
  end
  
  def dos_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    case old_boss.name
    when "Balore"
      if boss_entity.var_a == 2
        # Not actually Balore, this is the wall of ice blocks right before Balore.
        # We need to get rid of this because having this + a different boss besides Balore in the same room will load two different overlays into the same spot and crash the game.
        boss_entity.type = 0
        boss_entity.subtype = 0
        boss_entity.write_to_rom()
        return :skip
      end
    when "Gergoth"
      if GAME == "dos" && boss_entity.room.sector_index == 5
        # Condemned Tower. Replace the boss death flag checked by the floors of the tower so they check the new boss instead.
        boss_index = BOSS_ID_TO_BOSS_INDEX[new_boss_id]
        if boss_index.nil?
          boss_index = 0
        end
        
        game.fs.replace_hardcoded_bit_constant(0x0219EF44, boss_index)
      end
    when "Paranoia"
      if boss_entity.var_a == 1
        # Mini-paranoia.
        return :skip
      elsif boss_entity.var_a == 2
        # Normal Paranoia.
        
        # Mini Paranoia is hardcoded to disappear once Paranoia's boss death flag is set, so we need to switch him to use the new boss's boss death flag.
        boss_index = BOSS_ID_TO_BOSS_INDEX[new_boss_id]
        if boss_index.nil?
          boss_index = 0
        end
        
        game.fs.load_overlay(35)
        game.fs.replace_hardcoded_bit_constant(0x02305B1C, boss_index)
      end
    end
    
    case new_boss.name
    when "Flying Armor"
      boss_entity.x_pos = boss_entity.room.width * SCREEN_WIDTH_IN_PIXELS / 2
      boss_entity.y_pos = 0x50
    when "Balore"
      # Defaults to right-facing Balore.
      # But Balore's code has been modified so that he will face left and reposition himself if the player comes from the left.
      boss_entity.var_a = 1
      boss_entity.x_pos = 0x10
      boss_entity.y_pos = 0xB0
      
      if old_boss.name == "Puppet Master"
        # Puppet Master's room's left wall is farther to the right than most.
        boss_entity.x_pos += 0x90
      end
    when "Malphas"
      boss_entity.x_pos = boss_entity.room.width * SCREEN_WIDTH_IN_PIXELS / 2
      boss_entity.var_b = 0
    when "Dmitrii"
      boss_entity.var_a = 0 # Boss rush Dmitrii, doesn't crash when there are no events.
    when "Dario"
      boss_entity.var_b = 0
    when "Puppet Master"
      boss_entity.x_pos = 0x100
      boss_entity.y_pos = 0x60
      
      if old_boss.name == "Puppet Master"
        # Regular Puppet Master.
        boss_entity.var_a = 1
      else
        # Boss rush Puppet Master.
        boss_entity.var_a = 0
      end
    when "Gergoth"
      if old_boss_id == new_boss_id && GAME == "dos"
        # Normal Gergoth since he's in his tower.
        boss_entity.var_a = 1
      else
        # Set Gergoth to boss rush mode.
        boss_entity.var_a = 0
      end
    when "Zephyr"
      # Center him in the room.
      boss_entity.x_pos = boss_entity.room.width * SCREEN_WIDTH_IN_PIXELS / 2
      
      if boss_entity.room.width < 2
        # Small room, so we need boss rush Zephyr. Normal Zephyr's intro cutscene doesn't work unless the room is 2 screens tall or more.
        boss_entity.var_a = 0
      else
        # Normal Zephyr, with the cutscene.
        boss_entity.var_a = 1
      end
    when "Bat Company"
      
    when "Paranoia"
      # If Paranoia spawns in Gergoth's tall tower, his position and the position of his mirrors can become disjointed.
      # This combination of x and y seems to be one of the least buggy.
      boss_entity.x_pos = 0x1F
      boss_entity.y_pos = 0x80
      
      boss_entity.var_a = 2
    when "Aguni"
      boss_entity.var_a = 0
      boss_entity.var_b = 0
    when "Death"
      # If there are any candle's in Death's room, he will softlock the game when you kill him.
      # Why? I dunno.
      boss_entity.room.entities.each do |entity|
        if entity.is_special_object? && entity.subtype == 1 && entity.var_a != 0
          entity.type = 0
          entity.write_to_rom()
        end
      end
    when "Abaddon"
      # Abaddon's locusts always appear on the top left screen, so make sure he's there as well.
      boss_entity.x_pos = 0x80
      boss_entity.y_pos = 0xB0
    else
      boss_entity.var_a = 1
    end
  end
  
  def por_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    case old_boss.name
    when "Behemoth"
      if boss_entity.var_b == 2
        # Scripted Behemoth that chases you down the hallway.
        return :skip
      end
    end
    
    case new_boss.name
    when "Stella"
      boss_entity.var_a = 0 # Just Stella, we don't want Stella&Loretta.
    when "Brauner"
      boss_entity.var_a = 0 # Boss rush Brauner, doesn't try to reload the room when he dies.
    when "Balore", "Gergoth", "Zephyr", "Aguni", "Abaddon"
      dos_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    end
  end
  
  def ooe_adjust_randomized_boss(boss_entity, old_boss_id, new_boss_id, old_boss, new_boss)
    case old_boss.name
    when "Giant Skeleton"
      if boss_entity.var_a == 0
        # Non-boss version of the giant skeleton.
        return :skip
      elsif new_boss.name != "Giant Skeleton"
        boss_entity.room.entities.each do |entity|
          if entity.type == 2 && entity.subtype == 0x3E && entity.var_a == 1
            # Searchlights in Giant Skeleton's boss room. These will soft lock the game if Giant Skeleton isn't here, so we need to remove them.
            entity.type = 0
            entity.write_to_rom()
          end
        end
      end
    end
    
    case new_boss.name
    when "Giant Skeleton"
      boss_entity.var_a = 1 # Boss version of the Giant Skeleton
      boss_entity.var_b = 0 # Faces the player when they enter the room.
      
      # The boss version of the Giant Skeleton doesn't wake up until the searchlight is on him, but there's no searchlight in other boss rooms.
      # So we modify the line of code that checks if he should wake up to use the code for the common enemy Giant Skeleton instead.
      game.fs.write(0x02277EFC, [0xE3A01000].pack("V"))
    when "Wallman"
      # We don't want Wallman to be offscreen because then he's impossible to defeat.
      boss_entity.x_pos = 0xCC
      boss_entity.y_pos = 0xAF
    when "Blackmore"
      # Blackmore needs to be in this position or he becomes very aggressive and corners the player up against the wall.
      boss_entity.x_pos = 0x100
      boss_entity.y_pos = 0xA0
    when "Jiang Shi"
      unless old_boss.name == "Jiang Shi"
        # Jiang Shi needs a special object in his room for the boss doors to open since he doesn't die.
        room = boss_entity.room
        door_opener = Entity.new(room, room.fs)
        
        door_opener.y_pos = 0x80
        door_opener.type = 2
        door_opener.subtype = 0x24
        door_opener.var_a = 1
        
        room.entities << door_opener
        room.write_entities_to_rom()
      end
    end
  end
  
  DOS_FINAL_BOSS_TELEPORT_DATA = {
    :menace => [0xA, 0, 2, 0x80, 0xA0].pack("CCvvv"),
    :somacula => [0x10, 0, 2, 0x1A0, 0xB0].pack("CCvvv"),
  }
  
  def dos_set_soma_mode_final_boss(final_boss_name)
    return unless GAME == "dos"
    
    final_boss_tele_data = DOS_FINAL_BOSS_TELEPORT_DATA[final_boss_name]
    if final_boss_tele_data.nil?
      raise "Invalid final boss name: #{final_boss_name}"
    end
    
    game.fs.write(0x0222BE14, final_boss_tele_data)
  end
  
  # Menace doesn't appear in Julius mode.
  #def dos_set_julius_mode_final_boss(final_boss_name)
  #  return unless GAME == "dos"
  #  
  #  final_boss_tele_data = DOS_FINAL_BOSS_TELEPORT_DATA[final_boss_name]
  #  if final_boss_tele_data.nil?
  #    raise "Invalid final boss name: #{final_boss_name}"
  #  end
  #  
  #  game.fs.write(0x0222BE1C, final_boss_tele_data)
  #end
  
  def dos_randomize_final_boss
    return unless GAME == "dos"
    
    soma_mode_final_boss = [:menace, :somacula].sample(random: rng)
    dos_set_soma_mode_final_boss(soma_mode_final_boss)
    
    #julius_mode_final_boss = [:menace, :somacula].sample(random: rng)
    #dos_set_julius_mode_final_boss(julius_mode_final_boss)
  end
  
  def update_boss_doors(old_boss_id, new_boss_id, boss_entity)
    # Update the boss doors for the new boss
    old_boss_index = BOSS_ID_TO_BOSS_INDEX[old_boss_id] || 0
    new_boss_index = BOSS_ID_TO_BOSS_INDEX[new_boss_id] || 0
    ([boss_entity.room] + boss_entity.room.connected_rooms).each do |room|
      room.entities.each do |entity|
        if entity.type == 0x02 && entity.subtype == BOSS_DOOR_SUBTYPE && entity.var_b == old_boss_index
          entity.var_b = new_boss_index
          
          entity.write_to_rom()
        end
      end
    end
    
    if GAME == "dos"
      # Make the boss door use the same seal as the boss that was originally in this position so progression isn't affected.
      original_boss_door_seal = @original_boss_seals[old_boss_index]
      game.fs.write(MAGIC_SEAL_FOR_BOSS_LIST_START+new_boss_index*4, [original_boss_door_seal].pack("V"))
    end
  end
  
  def remove_boss_cutscenes
    # Boss cutscenes usually don't work without the original boss.
    
    obj_subtypes_to_remove = case GAME
    when "dos"
      [0x61, 0x63, 0x64, 0x69]
    when "por"
      []
    when "ooe"
      []
    end
    
    game.each_room do |room|
      room.entities.each do |entity|
        if entity.is_special_object? && obj_subtypes_to_remove.include?(entity.subtype)
          entity.type = 0
          entity.write_to_rom()
        end
      end
    end
    
    if GAME == "dos"
      dmitriis_malachi = game.areas[0].sectors[4].rooms[0x10].entities[6]
      dmitriis_malachi.type = 0
      dmitriis_malachi.write_to_rom()
    end
  end
end

# encoding: utf-8
require 'tmpdir'
require 'json'
require 'logger'
require 'fileutils'
require 'open3'
require 'shellwords'

SYM2NUM = { ┼: [1,1,1,1], :' ' => [0,0,0,0],
            ┐: [0,0,1,1], └: [1,1,0,0], ┘: [1,0,0,1], ┌: [0,1,1,0],
            ─: [0,1,0,1], │: [1,0,1,0],
            ├: [1,1,1,0], ┬: [0,1,1,1], ┤: [1,0,1,1], ┴: [1,1,0,1],
            ╴: [0,0,0,1], ╶: [0,1,0,0], ╷: [0,0,1,0], ╵: [1,0,0,0] }
NUM2SYM = SYM2NUM.invert
CACHE_FILE = 'tile_size.json'
ROT_TIME = 0.6
THRESHOLD = '59%'

logger = Logger.new($stdout).tap do |lgr|
  lgr.level = Logger::DEBUG
end

FileUtils.touch(CACHE_FILE)
content = File.read(CACHE_FILE)
content = '{}' if content.empty?
cache = Hash[JSON.parse(content).map {|k, v| [k.to_f, v]}]

Dir.mktmpdir do |dir|
  logger.debug("Temp dir: #{dir}")

  loop do
    # thresholded screenshot
    threshold_png = File.join(dir, 'thres.png').shellescape
    logger.debug('Taking screenshot and thresholding...')
    system("adb shell screencap -p | sed 's/\r$//' | convert png:- -threshold #{THRESHOLD} #{threshold_png}")

    # get the trimming size and offset of the thresholded screenshot
    w, h, x, y = /(\d+)x(\d+)\+(\d+)\+(\d+)/.match(`identify -format "%@" #{threshold_png}`).captures.map(&:to_f)

    # see if the trimmed image can be divided by cached tile size
    tile_size, h_extra_edges, v_extra_edges = cache.map do |tile_size, extra_edges|
      possibilities = extra_edges.repeated_combination(2)
      h_extra_edges = possibilities.detect {|a, b| (w-a-b)%tile_size == 0}
      v_extra_edges = possibilities.detect {|a, b| (h-a-b)%tile_size == 0}
      [tile_size, h_extra_edges, v_extra_edges] if h_extra_edges && v_extra_edges
    end.find(&:itself)
    logger.debug("Tile size: #{tile_size || 'unsure'}")

    # position and dimensions of the board
    left, top, width, height = nil

    # if we're using the cached tile size
    # guess the left, top, width, height of the board
    unless tile_size.nil?
      # center of screen
      cx, cy = /(\d+)x(\d+)/.match(`identify -format "%wx%h" #{threshold_png}`).captures.map {|n| n.to_f*0.5}
      left = h_extra_edges.permutation.map do |a, b|
        before = (tile_size-a)%tile_size
        after = (tile_size-b)%tile_size
        [(((x-before)+(x+w+after))*0.5 - cx).abs % (tile_size*0.5), x-before]
      end.min_by(&:first)[1]
      top = v_extra_edges.permutation.map do |a, b|
        above = (tile_size-a)%tile_size
        below = (tile_size-b)%tile_size
        [(((y-above)+(y+h+below))*0.5 - cy).abs % (tile_size*0.5), y-above]
      end.min_by(&:first)[1]
      width = ((x+w-left)/tile_size).ceil*tile_size
      height = ((y+h-top)/tile_size).ceil*tile_size

    # if unsure about tile size,
    # tap a tile 3 times to find out the tile size
    else
      logger.debug('Unsure about tile size. Figuring out tile size...')

      # store the thresholded screenshots of the 4 orientations of a tile
      all_oris = Array.new(4).tap {|ao| ao[0] = threshold_png}

      # locate the first black pixel
      fx, fy = /(\d+),(\d+)/.match(`convert #{all_oris[0]} -trim txt:- | grep '(0,0,0)' | head -n1`).captures.map(&:to_f)
      fx, fy = [fx+x, fy+y]

      # 3 other orientations
      (1..3).each do |ori|
        logger.debug('Tap...')
        system("adb shell input tap #{fx} #{fy}")
        sleep(ROT_TIME)
        all_oris[ori] = File.join(dir, "#{ori}.png").shellescape
        pid = spawn("adb shell screencap -p | sed 's/\r$//' | convert png:- -threshold #{THRESHOLD} #{all_oris[ori]}")
        Process.detach(pid)
        sleep(0.5)
      end
      # tap one more time to get it back to original orientation
      logger.debug('Tap...')
      system("adb shell input tap #{fx} #{fy}")

      or_png = File.join(dir, 'or.png').shellescape # all 4 screenshots or'ed together
      and_png = File.join(dir, 'and.png').shellescape # all 4 screenshots and'ed together

      logger.debug("Or'ing...")
      p1 = spawn("composite #{all_oris[0]} -compose multiply #{all_oris[1]} - | composite - -compose multiply #{all_oris[2]} - | composite - -compose multiply #{all_oris[3]} #{or_png}")
      logger.debug("And'ing...")
      p2 = spawn("composite #{all_oris[0]} -compose lighten #{all_oris[1]} - | composite - -compose lighten #{all_oris[2]} - | composite - -compose lighten #{all_oris[3]} #{and_png}")

      # wait for both to be finished
      Process.wait(p1) and Process.wait(p2)

      # diff or_png and and_png, and get the trimming offset and size of the result
      logger.debug('Diffing...')
      tw, th, tx, ty = /(\d+)x(\d+)\+(\d+)\+(\d+)/.match(`composite #{or_png} -compose difference #{and_png} - | identify -format "%@" -`).captures.map(&:to_f)

      # width and height should be equal
      unless tw == th
        logger.error("Tile not square? (#{tw}x#{th}) Try again...")
        next
      end

      tile_size = tw
      extra_edges = [(y+h-ty)%th, (tx-x)%tw, (x+w-tx-tw)%tw, (ty+th-y)%th, 0.0].uniq

      logger.debug("Tile size: #{tile_size}")

      # write to cache file
      cache[tile_size] ||= []
      cache[tile_size].concat(extra_edges).uniq!
      cache_json = cache.to_json
      logger.debug("Cache: #{cache_json}")
      File.open(CACHE_FILE, 'w') {|f| f.puts(cache_json)}

      # with the exact position of the tile
      # we know the top, left, width, height of the board
      left = tx-((tx-x)/tw).ceil*tw
      top = ty # the tile has to be at the top
      width = ((x+w-left)/tw).ceil*tw
      height = ((y+h-top)/th).ceil*th
    end

    logger.debug("Board: #{{left: left, top: top, width: width, height: height}}")
    raise 'width not divisible by tile_size' unless width%tile_size == 0
    raise 'height not divisible by tile_size' unless height%tile_size == 0

    logger.debug('Extracting board...')
    board = `convert #{threshold_png}[#{width}x#{height}+#{left}+#{top}] -compress none pbm:- | tail -n +3`.split
    raise 'board.size not right' unless board.size == width*height

    nrows, ncols = [height.div(tile_size), width.div(tile_size)]

    grid = {}
    # r,c,row,col,... are 1-indexed
    [*1..nrows].product([*1..ncols]).each {|r, c| grid[[r,c]] = [0,0,0,0]} # top,right,bottom,left

    tile_half = tile_size.div(2)

    [*1..nrows].product([*1..ncols]).each do |r, c|
      px, py = [(c-1)*tile_size, (r-1)*tile_size]
      [[px+tile_half,py],[px+tile_size-1,py+tile_half],[px+tile_half,py+tile_size-1],[px,py+tile_half]].each_with_index do |(bx, by), ind|
        grid[[r,c]][ind] = 1 if board[(by*width+bx).to_i] == '1'
      end
    end

    printable_board = [*1..nrows].map do |row|
      [*1..ncols].map {|col| NUM2SYM[grid[[row,col]]]}.join + "\n"
    end.join.chomp
    logger.debug("Board:\n#{printable_board}")

    # iterate through the tiles in 'snake' order
    ilist = (1..nrows).flat_map do |r|
      row = (1..ncols).map {|c| [r, c]}
      r.odd? ? row.reverse : row
    end

    solv_grid = {}
    # put 2 extra rows, and cols on the sides as boundaries
    [0, nrows+1].product([*(0..ncols+1)]).each {|r,c| solv_grid[[r,c]] = [0,0,0,0]}
    [*(0..nrows+1)].product([0, ncols+1]).each {|r,c| solv_grid[[r,c]] = [0,0,0,0]}

    logger.debug('Solving...')
    cursor = 0
    until ilist[cursor].nil?
      row, col = ilist[cursor]
      if solv_grid[[row,col]].nil? # copy original tile into grid
        solv_grid[[row,col]] = grid[[row,col]].dup
      elsif solv_grid[[row,col]].rotate! == grid[[row,col]] # backtrack if rotated back to original
        cursor -= 1
        solv_grid[[row,col]] = nil
        next
      end

      # conditions to be satisfied
      const_sat = [[-1,0],[0,1],[1,0],[0,-1]].map.with_index do |(ro,co), ind|
        adj = solv_grid[[row+ro,col+co]]
        adj.nil? || solv_grid[[row,col]][ind] == adj[(ind+2)%4]
      end.all?

      # go to next tile if conditions satisfied
      cursor += 1 if const_sat
    end

    solution = [*(1..nrows)].map do |row|
      [*(1..ncols)].map do |col|
        [0,1,2,3].detect do |rot|
          grid[[row,col]].rotate(-rot) == solv_grid[[row,col]]
        end
      end.join
    end.join("\n").chomp
    logger.debug("Solution:\n#{solution}")

    logger.debug('Applying solution...')
    solution.split.each_with_index do |ln, r|
      ln.chars.map(&:to_i).each_with_index do |rot, c|
        rot.times do
          pid = spawn("adb shell input tap #{left+10+c*tile_size} #{top+10+r*tile_size}")
          Process.detach(pid)
          sleep 0.3
        end
      end
    end
    logger.debug('Done')

    logger.debug('Wait for 7 seconds...')
    sleep(3)
    system('adb shell input tap 100 100')
    sleep(4)
  end
end

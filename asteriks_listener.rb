module AsteriksListener
	require 'net/telnet'
	require 'json'

	class Connection < Net::Telnet
		SERVER  	= 'mail.gemir.ru'
		PORT			= 3850
		LOGIN			= "Action: Login\nUsername: crmmanager\nSecret: CrMPasswrd112\n"
		MAX_FAILS = 10
		attr_accessor :events, :cnt


		def initialize(debug = false)
			super("Host" => SERVER,
						"Port" => PORT,
						"Output_log" => "asteriks_log.log",
						"Telnetmode" => false
					  #	"Waittime"	 => 10				
						)
			self.events = {}
		end

		def authorize()	
			@sock.readline	# read just one line after connect - Asterisk Call Manager/1.1 	
			response = AMI_Event.new (self.cmd("String" => LOGIN,
																				 "Waittime" => 10,
																				 "Match" => /\s{2}/n)
															 )
			if response.event["Response"] == 'Success'							
				true
			else
				STDERR.puts "Something goes wrong!\nAsteriks says: #{response.event['Message']}"
				false
			end
		end

		def listen_events
			event = AMI_Event.new
			self.cnt = 0			
			while self.cnt != 200 do
				line = ''	
				# until /\s{4}/n === line do
				# 	line += @sock.gets
				# 	@log.puts line.inspect
				# end
				line += @sock.gets "\r\n\r\n"
				event.read_event line
				process_event event.event				
				
				STDERR.puts "#{self.cnt}\n#{line}"				
				self.cnt += 1

			end
			self.events.each do |k, v|
				@log.puts "\n\n===========#{k}=============\n"
				v.each do |i, j|
					@log.puts "\t#{i}\n"
					j.each do |x, z|
						@log.puts "\t\t#{x}: #{z}\n" 
					end
				end
			end
		end

		def send_cmd(string)
			# asterisk command ends with 2 linebreaks
			write string + "\n\n"
		end

		def process_event(ami_event)			
			unless ami_event.empty?	
				#@log.puts ami_event["Event"]			
				case ami_event["Event"]
					when "Dial"						
						if ami_event["SubEvent"] == 'Begin'							
							#@log.puts "Dial started for SIP #{ami_event["Channel"]} \n\n"
							save_event ami_event
						elsif ami_event["SubEvent"] == 'End'							
							#@log.puts "Dial ended for SIP #{ami_event["Channel"]} \n\n"
							save_event ami_event
						end
					when 'NewCallerid'
						#@log.puts "New Caller ID SIP = #{ami_event["Channel"]} and UniqueID = #{ami_event["Uniqueid"]} and Calleridnum = #{ami_event["CallerIDNum"]}\n"
						save_event ami_event
					when 'Bridge'				
						#@log.puts "Bridge #{ami_event["Bridgestate"]}\n#{ami_event["Channel1"]} to #{ami_event["Channel2"]}\nu #{ami_event["CallerID1"]} to #{ami_event["CallerID2"]}\n\n"
						save_event ami_event					
					when 'Hangup'
						#@log.puts "Hangup #{ami_event["Channel"]}, number: #{ami_event["CallerIDNum"]}\n\n"
						save_event ami_event
						
				end


			end
		end

		def save_event(ami_event)
			if ami_event.has_key? "Channel"
				sip = %r{^\w{,5}/(\w*)}.match ami_event["Channel"]
				if sip
					unless self.events.has_key? sip[1]
						self.events[sip[1]] = {}
					end
					self.events[sip[1]][ami_event["Event"] + "   #{Time.now.hour}:#{Time.now.min}"] = ami_event
				end
			elsif ami_event.has_key? "Channel1"
				sip = %r{^\w{,5}/(\w*)}.match ami_event["Channel1"]
				if sip
					unless self.events.has_key? sip[1]
						self.events[sip[1]] = {}
					end
					self.events[sip[1]][ami_event["Event"] + "   #{Time.now.hour}:#{Time.now.min}"] = ami_event
				end
			end
		end
	end

	class AMI_Event
		attr_accessor :source_string, :event		

		def initialize(response_text = '')
			unless response_text.empty?	
				read_event(response_text)
			end
		end

		def read_event(response_text)
			# convert AMI response to hash
			@source_string = response_text			
			response_array = []			
			@source_string.split("\n").each do |str|
				key_value = str.strip.split(': ')
				# sometimes, fields are empty - 'AccountCode: ' - we don't want that
				if key_value.count > 1
					response_array << key_value
				end
			end
			self.event = Hash[response_array]
		end

		#def event=(string)			
			#@event = Hash[*string.split("\n").map{ |s| s.split(": ")}.flatten]
		#end

		def to_json
			self.event.to_json
		end
	end



	class AMI_EventProcessor

	end


end

include AsteriksListener

conn = Connection.new
if conn.authorize
	conn.listen_events
end
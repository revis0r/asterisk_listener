module AsteriksListener
	require 'net/telnet'
	require 'json'

	class Connection < Net::Telnet
		SERVER  	= 'mail.gemir.ru'
		PORT			= 3850
		LOGIN			= "Action: Login\nUsername: crmmanager\nSecret: CrMPasswrd112\n"
		MAX_FAILS = 10

		def initialize(debug = false)
			super("Host" => SERVER,
						"Port" => PORT,
						"Output_log" => "asteriks_log.log",
						"Telnetmode" => false				
						)
		end

		def authorize()	
			@sock.readline	# read just one line after connect - Asterisk Call Manager/1.1 	
			response = AMI_Event.new (self.cmd("String" => LOGIN,
																				 "Waittime" => 10,
																				 "Match" => /\s{2}/n)#{|mess| STDERR.puts mess}
															 )
			if response.event["Response"] == 'Success'
				true
			else
				STDERR.puts "Something goes wrong!\nAsteriks says: #{response.event['Message']}"
			end
		end

		def send_cmd(string)
			# asterisk command ends with 2 linebreaks
			write string + "\n\n"
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
			@source_string = response_text
			#self.event=(response_text)
			response_array = []			
			@source_string.split("\n").each do |str|
				key_value = str.split(': ')
				# sometimes, fields are empty - 'AccountCode: ' - we don't want that
				if key_value.count > 1
					response_array << key_value
				end
			end
			self.event = Hash[response_array]
		end

		#def event
			#@event
		#end

		#def event=(string)
			# convert AMI response to hash
			#@event = Hash[*string.split("\n").map{ |s| s.split(": ")}.flatten]
		#end

		def to_json
			self.event.to_json
		end
	end


end

include AsteriksListener

conn = Connection.new
str = conn.authorize
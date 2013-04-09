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
					  #	"Waittime"	 => 10				
						)
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
			count = 0				
			while IO::select([@sock]) do
				line = ''	
				until /\s{2}/n === line do
					line += @sock.readpartial(2048)					
				end
				event.read_event line
				count += 1
				
				@log.print( "====#{count}====\n\n #{event.event.inspect}\n\n" )
				
				STDERR.puts line
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
			# convert AMI response to hash
			@source_string = response_text			
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

		#def event=(string)			
			#@event = Hash[*string.split("\n").map{ |s| s.split(": ")}.flatten]
		#end

		def to_json
			self.event.to_json
		end
	end


end

include AsteriksListener

conn = Connection.new
if conn.authorize
	conn.listen_events
end
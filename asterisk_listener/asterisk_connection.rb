module AsteriskListener
	class AsteriskConnection < Net::Telnet
		SERVER  	= 'mail.gemir.ru'
		PORT			= 3850
		LOGIN			= "Action: Login\nUsername: crmmanager\nSecret: CrMPasswrd112\nEvents: call\n"
		MAX_FAILS = 10
		attr_accessor :events, :cnt


		def initialize(debug = false)
			super("Host" => SERVER,
						"Port" => PORT,
						#"Output_log" => "asteriks_log.log",
						"Telnetmode" => false
					  #	"Waittime"	 => 10				
						)
			self.events = {}
			# Connect to DB
			begin
				@mongo_connection = Mongo::MongoClient.new('localhost', 27017)
			rescue Mongo::ConnectionFailure
				@mongo_connection = Mongo::MongoClient.new
			else				
				@db = @mongo_connection.db("asterisk_log")
				@db["events"].remove
				@db["calls"].remove
				@db["raw_dials"].remove
				@db["raw_hangups"].remove
				@processor = AMI_EventProcessor.new @db
			end
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
			while self.cnt != 1600 do
				line = ''					
				line += @sock.gets "\r\n\r\n"
				event.read_event line
				process_event event.event				
				
				STDERR.puts "#{self.cnt}\n#{line}" if ARGV.include? "event_log"		
				self.cnt += 1

				# check MongoDB connection
				if !@mongo_connection.connected?
					@mongo_connection.reconnect
					if !@mongo_connection.connected?
						raise Mongo::ConnectionFailure, 'DB error! Connection to DB lost =('
					end
				end
			end

		end

		def send_cmd(string)
			# asterisk command ends with 2 linebreaks
			write string + "\n\n"
		end

		def process_event(event)			
			unless event.empty?	

				case event["Event"]
					when "Dial"						
						@processor.process_dial event
					when 'NewCallerid'
						@processor.process_new_caller event
					when 'Bridge'				
						@processor.process_bridge event					
					when 'Hangup'
						@processor.process_hangup event						
				end
			end
		end

		def save_event(ami_event)
			# Saves event in event instance variable in format: {"SIP" => { event-hash } }
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
end
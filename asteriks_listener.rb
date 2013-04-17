require 'rubygems'
require 'mongo'


module AsteriskListener
	require 'net/telnet'
	require 'json'
	

	class AsteriskConnection < Net::Telnet
		SERVER  	= 'mail.gemir.ru'
		PORT			= 3850
		LOGIN			= "Action: Login\nUsername: crmmanager\nSecret: CrMPasswrd112\nEvents: call\n"
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
			# Connect to DB
			begin
				@mongo_connection = Mongo::MongoClient.new('localhost', 27017)
			rescue Mongo::ConnectionFailure
				@mongo_connection = Mongo::MongoClient.new
			else				
				@db = @mongo_connection.db("asterisk_log")
				events_db = @db["events"]	
				events_db.drop()
				@processor = AMI_EventProcessor.new events_db
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
			while self.cnt != 200 do
				line = ''					
				line += @sock.gets "\r\n\r\n"
				event.read_event line
				process_event event.event				
				
				STDERR.puts "#{self.cnt}\n#{line}" if ARGV.include? "event_log"		
				self.cnt += 1
			end

			# self.events.each do |k, v|
			# 	@log.puts "\n\n===========#{k}=============\n"
			# 	v.each do |i, j|
			# 		@log.puts "\t#{i}\n"
			# 		j.each do |x, z|
			# 			@log.puts "\t\t#{x}: #{z}\n" 
			# 		end
			# 	end
			# end
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

		def to_json
			self.event.to_json
		end
	end



	class AMI_EventProcessor

		def initialize(db_instance)
			@events_db = db_instance
		end

		def process_dial(event)
			STDERR.puts 'dial'
			@events_db.insert({"event" => "dial"})
		end

		def process_new_caller(event)
			STDERR.puts 'new_caller'
			@events_db.insert({"event" => "new_caller"})
		end

		def process_hangup(event)
			STDERR.puts 'hangup'
			@events_db.insert({"event" => "hangup"})
		end

		def process_bridge(event)
			STDERR.puts 'bridge'
			@events_db.insert({"event" => "bridge"})
		end

	end

end

include AsteriskListener

conn = AsteriskConnection.new
if conn.authorize
	conn.listen_events
end
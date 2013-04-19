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
				@db["events"].remove
				@db["calls"].remove
				@db["raw_dials"].remove
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
			while self.cnt != 500 do
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
				# sometimes, fields are empty - 'AccountCode: ' - then it must become ["AccountCode", ""]
				key_value.push ''	if key_value.count == 1
				
				response_array << key_value
			end
			self.event = Hash[response_array]
		end		

		def to_json
			self.event.to_json
		end
	end



	class AMI_EventProcessor
		LOCAL_REGEXP = %r{^L}
		SIP_REGEXP	 = %r{^\w{,5}/(\w*)}

		def initialize(db_instance)
			@db = db_instance
		end

		def process_dial(e)
			if e["SubEvent"] == "Begin"
				
				# check if internal call, then skip
				unless LOCAL_REGEXP === e["Channel"] && LOCAL_REGEXP === e["Destination"]
					 
					sip = SIP_REGEXP.match e["Channel"] # extract sip
					tmp_caller_id = e["CallerIDNum"]

					# create init call record				
					call_record_id = @db['calls'].insert({
						'sip' => sip[1],
						'start_time' => Time.now						
					})	

					# attemp to detect call direction
					if (LOCAL_REGEXP === e["Channel"]) && (not LOCAL_REGEXP === e["Destination"])						
						call_direction = 'outbound'
						
						@db['events'].insert({
							'sip' => sip[1],
							'event' => {
								'asterisk_id' 	 => e['DestUniqueID'],
								'call_record_id' => call_record_id,
								'channel'    		 => e['Channel'],
								'remote_channel' => e['Destination'],
								'call_state' => 'NeedID',
								'direction'  => 'O', # O = outbound call
								'CallerID'   => tmp_caller_id,
								'timestamp_call'  => Time.now.to_i						
							}
						})
					elsif (not LOCAL_REGEXP === e['Channel'])
						call_direction = 'inbound'
						
						@db['events'].insert({
							'sip' => sip[1],
							'event' => {
								'asterisk_id' 	 => e['UniqueID'],
								'call_record_id' => call_record_id,
								'channel'    		 => e['Destination'],
								'remote_channel' => e['Channel'],
								'call_state' => 'Dial',
								'direction'  => 'I', # I = inbound call
								'CallerID'   => tmp_caller_id,
								'timestamp_call'   => Time.now.to_i,
								'asterisk_dest_id' => e['DestUniqueID']						
							}
						})
					end

					# update call direction
					@db['calls'].update({'_id' => call_record_id}, {'$set' => {'direction' => call_direction}})							

					@db['raw_dials'].insert(e)				
				end
			end
		end

		def process_new_caller(e)			
			tmp_caller_id = e["CallerIDNum"]
			id 						= e["Uniqueid"]
			@db['events'].update(
				# where event: asterisk_id = id
				{ "event.asterisk_id" => id },
				# change event call state to Dial and update callerID
				{ "$set" => {"event.call_state" => "Dial", "event.CallerID" => tmp_caller_id } } 
			)			
		end

		def process_hangup(e)
			
		end

		def process_bridge(e)
			# find event.direction with asterisk_id = e.Uniqueid2 or asterisk_dest_id = e.Uniqueid2
			call = @db["events"].find({
				'$or' => [
						{'event.asterisk_id' 			=> e["Uniqueid2"]},
						{'event.asterisk_dest_id' => e['Uniqueid2']}
					]
			}, {:fields => ['event.direction'], :limit => 1 }).to_a

			unless call.empty?
				direction = call[0]['event']['direction'] 

				direction == 'I' ? call_direction = 'Inbound' : call_direction = 'Outbound'

				if call_direction == 'Inbound'
					# set CONNECTED state and timestamp, when connection established
					@db['events'].update({
						'$or' => [
								{'event.asterisk_dest_id' => e['Uniqueid1']},
								{'event.asterisk_dest_id' => e['Uniqueid2']}
							]}, 
						{
							'$set' => {'event.call_state' => 'Connected', 'event.timestamp_link' => Time.now.to_i}
						})

					# TODO: Test, after hangup event implementation
					# TODO: Test, why it finds records without hangup
					# to delete all the extra inbound records created by the hangup event.
					res = @db['events'].find({
						# where asterisk_id = e.Uniqueid1
						'event.asterisk_id' 		 => e['Uniqueid1'],
						# AND asterisk_dest_id NOT EQUAL e.Uniqueid2
						'event.asterisk_dest_id' => {'$ne' => e['Uniqueid2']}
						}, 
						{:fields => ['event.call_record_id']}).to_a
					
					unless res.empty?
						STDERR.puts "++++++++Found #{res.count} record!\nDeleting...\n Calls count = #{@db['calls'].count}"						
						res.each do |record|							
							@db['calls'].remove({"_id" => record['event']['call_record_id']})
						end
						STDERR.puts "Calls count after deletion = #{@db['calls'].count}"

					end

				else
					# Outbound
					# set CONNECTED state and timestamp, when connection established for Outbound bridge event
					@db['events'].update({
						'$or' => [
								{'event.asterisk_id' => e['Uniqueid1']},
								{'event.asterisk_id' => e['Uniqueid2']}
							]}, 
						{
							'$set' => {'event.call_state' => 'Connected', 'event.timestamp_link' => Time.now.to_i}
						})


				end

			end			
		end

	end

end

include AsteriskListener

conn = AsteriskConnection.new
if conn.authorize
	conn.listen_events
end
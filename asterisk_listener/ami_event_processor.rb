module AsteriskListener
	class AMI_EventProcessor
		LOCAL_REGEXP 				= %r{^L}
		SIP_REGEXP	 				= %r{^\w{,5}/(\w*)}
		DIALSTRING_REGEXP 	= %r{^(\d*)}
		INTERNAL_NUM_REGEXP = %r{^\d{4}$}

		def initialize(db_instance)
			@db = db_instance
		end

		def extract_sip(sip)
			SIP_REGEXP.match(sip)[1]
		end

		def process_dial(e)
			if e["SubEvent"] == "Begin"
				initiator_sip 	= extract_sip e['Channel']
				destination_sip = extract_sip e['Destination']

				# check if internal call (contains Local/xxxxyyyyy) OR local call (from xxxx to yyyy), then skip 
				unless (
					(LOCAL_REGEXP === e["Channel"] || LOCAL_REGEXP === e["Destination"]
						) || (
						INTERNAL_NUM_REGEXP === initiator_sip && INTERNAL_NUM_REGEXP === destination_sip)
				)					 
					
					tmp_caller_id = e["CallerIDNum"]
					call_start_time = Time.now.to_i

					# if Initiator (channel) number is internal (4-digit number)
					# AND
					# Destination number is NOT internal
					# Then it's outbound call
					if((INTERNAL_NUM_REGEXP === initiator_sip) && (not INTERNAL_NUM_REGEXP === destination_sip))						
						call_direction = 'outbound'

						# create init call record				
						call_record_id = @db['calls'].insert({
							'sip' => initiator_sip,
							'start_time' => call_start_time,
							'direction'  => call_direction
						})
						
						@db['events'].insert({
							'sip' => initiator_sip,
							'event' => {
								'asterisk_id' 	 => e['DestUniqueID'],
								'call_record_id' => call_record_id,
								'channel'    		 => e['Channel'],
								'remote_channel' => e['Destination'],
								'call_state' => 'NeedID',
								'direction'  => 'Outbound',
								'CallerID'   => tmp_caller_id,
								'timestamp_call'  => Time.now.to_i						
							}
						})
					elsif((not INTERNAL_NUM_REGEXP === initiator_sip) && (INTERNAL_NUM_REGEXP === destination_sip))						
						call_direction = 'inbound'

						# create init call record				
						call_record_id = @db['calls'].insert({
							'sip' => destination_sip,
							'start_time' => call_start_time,
							'direction'  => call_direction
						})
						
						@db['events'].insert({
							'sip' => destination_sip,
							'event' => {
								'asterisk_id' 	 => e['UniqueID'],
								'call_record_id' => call_record_id,
								'channel'    		 => e['Destination'],
								'remote_channel' => e['Channel'],
								'call_state' => 'Dial',
								'direction'  => 'Inbound',
								'CallerID'   => tmp_caller_id,
								'timestamp_call'   => Time.now.to_i,
								'asterisk_dest_id' => e['DestUniqueID']						
							}
						})
					end											

					# insert raw event (for debug info)
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
			id   = e['Uniqueid']			

			#find corresponding call
			call = @db["events"].find({
				'$or' => [
						{'event.asterisk_dest_id' => id},
						{'event.asterisk_id' 			=> id}
					]
			}, {:fields => ['event.direction'], :limit => 1 }).to_a

			unless call.empty?
				hangup_time = Time.now.to_i
				direction = call[0]['event']['direction'] 
				#direction == 'I' ? call_direction = 'Inbound' : call_direction = 'Outbound'

				if direction == 'Outbound'
					result = @db['events'].update({
						# where asterisk_id = Hangup event Uniqueid
						"event.asterisk_id"  => id}, \
						# change event call state to Hangup, and add hangup_timestamp
						{"$set" => {
							'event.call_state' => 'Hangup',
							'event.timestamp_hangup' => hangup_time,
							'event.hangup_cause' 		 => e['Cause'],
							'event.hangup_cause_txt' => e['Cause-txt']
							}
						})

					if result['n'] > 0 && result['updatedExisting'] == true #update success

						updated_call = @db['events'].find_one({'event.asterisk_id' => id}) #hash
						#calculate call duration
						failed_call = false
						call_duration_sec = 0

						if updated_call['event'].has_key? 'timestamp_link'
							call_link_time 		= updated_call['event']['timestamp_link']
							call_duration_raw = hangup_time - call_link_time
							# recalculate in hours and minutes
							call_duration_minutes = call_duration_raw / 60
							call_duration_hours   = call_duration_minutes / 60
							call_duration_sec			= call_duration_raw % 60
							call_duration 				= "#{call_duration_hours}:#{call_duration_minutes}:#{call_duration_sec}"
						else
							# if there is no link timestamp then call is failed
							failed_call = true
						end

						if !failed_call && call_duration_sec > 0
							STDERR.puts "Success outbound call. length: #{call_duration_raw} seconds;  duration: #{call_duration}"
							# update success call
							@db['calls'].update(
								{'_id' => updated_call['event']['call_record_id']},
								{'$set' => {
									'minutes' => call_duration_minutes,
									'seconds' => call_duration_sec,
									'hours'		=> call_duration_hours,
									'duration'=> call_duration
									}
								}
							)							
						else							
							STDERR.puts 'Failed outbound call. removing corresponding event and call record...'							
							@db['calls'].remove({'_id' => updated_call['event']['call_record_id']})
							@db['events'].remove({'_id' => updated_call['_id']})
						end
					end

				else #Inbound call hangup event
					result = @db['events'].update({
						# where asterisk_dest_id = Hangup event Uniqueid
						# ALL DIFFERENCE - astersik_DEST_id. not asterisk_id
						"event.asterisk_dest_id"  => id}, \
						# change event call state to Hangup, and add hangup_timestamp
						{"$set" => {
							'event.call_state' => 'Hangup',
							'event.timestamp_hangup' => hangup_time,
							'event.hangup_cause' 		 => e['Cause'],
							'event.hangup_cause_txt' => e['Cause-txt']
							}
						})

					if result['n'] > 0 && result['updatedExisting'] == true #update success

						updated_call = @db['events'].find_one({'event.asterisk_dest_id' => id}) #hash
						#calculate call duration
						failed_call = false
						call_duration_sec = 0

						if updated_call['event'].has_key? 'timestamp_link'
							call_link_time 		= updated_call['event']['timestamp_link']
							call_duration_raw = hangup_time - call_link_time
							# recalculate in hours and minutes
							call_duration_minutes = call_duration_raw / 60
							call_duration_hours   = call_duration_minutes / 60
							call_duration_sec			= call_duration_raw % 60
							call_duration 				= "#{call_duration_hours}:#{call_duration_minutes}:#{call_duration_sec}"
						else
							# if there is no link timestamp then call is failed
							failed_call = true
						end

						if !failed_call && call_duration_sec > 0
							STDERR.puts "Success inbound call. length: #{call_duration_raw} seconds;  duration: #{call_duration}"
							# update success call
							@db['calls'].update(
								{'_id' => updated_call['event']['call_record_id']},
								{'$set' => {
									'minutes' => call_duration_minutes,
									'seconds' => call_duration_sec,
									'hours'		=> call_duration_hours,
									'duration'=> call_duration
									}
								}
							)							
						else							
							STDERR.puts 'Failed inbound call. removing corresponding event and call record...'							
							@db['calls'].remove({'_id' => updated_call['event']['call_record_id']})
							@db['events'].remove({'_id' => updated_call['_id']})
						end
					end
				end
			end
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

				#direction == 'I' ? call_direction = 'Inbound' : call_direction = 'Outbound'

				if direction == 'Inbound'
					# set CONNECTED state and timestamp, when connection established
					@db['events'].update({
						'$or'    => [
								{'event.asterisk_dest_id'   => e['Uniqueid1']},
								{'event.asterisk_dest_id'   => e['Uniqueid2']}
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
						res.each do |record|							
							@db['calls'].remove({"_id" => record['event']['call_record_id']})
						end					

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
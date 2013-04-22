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

					# create init call record				
					call_record_id = @db['calls'].insert({
						'sip' => initiator_sip,
						'start_time' => Time.now						
					})	

					# if Initiator (CallerIDNum) number is internal (4-digit number)
					# AND
					# Destination number is NOT internal
					# Then it's outbound call
					if((INTERNAL_NUM_REGEXP === initiator_sip) && (not INTERNAL_NUM_REGEXP === destination_sip))						
						call_direction = 'outbound'
						
						@db['events'].insert({
							'sip' => initiator_sip,
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
					elsif((not INTERNAL_NUM_REGEXP === initiator_sip) && (INTERNAL_NUM_REGEXP === destination_sip))						
						call_direction = 'inbound'
						
						@db['events'].insert({
							'sip' => destination_sip,
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
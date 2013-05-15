module AsteriskListener
	# Event class for ami-events handling 

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
end
# Little Sinatra server for saved events querying

require 'rubygems'
require 'sinatra'
require 'mongo'
require 'json'

begin
	mongo_client = Mongo::MongoClient.new('localhost', 27017)	
rescue Mongo::ConnectionFailure
	mongo_client = Mongo::MongoClient.new
else				
	@@db = mongo_client.db("asterisk_log")		
end

# succeseeded calls
get %r{/calls/(\d*)} do |sip|  
  @calls = @@db['calls'].find({
  	'sip' => sip 
  	}, 
  	:fields => {
  		'_id' => false
  		}
  	)  
  content_type :json
  @calls.to_a.to_json
end

# events for a call
get %r{/events/(\d*)} do |sip|
	# retrieve last stored event for this sip number (limit 1)
  @calls = @@db['events'].find({
  	'sip' => sip 
  	}, 
  	:fields => {'_id' => false, 'sip' => 1,'event.CallerID' => 1, 'event.call_state' => 1,'event.direction' => 1 },
  	:sort		=> {'_id' => -1},
  	:limit	=> 1
  ) rescue {}  
  content_type :json
  "asteriskResultCallBack(#{@calls.to_a[0].to_json})"
end
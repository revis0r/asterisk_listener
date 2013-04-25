require 'rubygems'
require 'mongo'
require 'net/telnet'
require 'json'

require './asterisk_listener/asterisk_connection'
require './asterisk_listener/ami_event_processor'
require './asterisk_listener/ami_event'

include AsteriskListener

conn = AsteriskConnection.new
if conn.authorize
	conn.listen_events
end
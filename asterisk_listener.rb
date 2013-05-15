# run this script to launch asterisk listener
# run with argument "-event_log" to see some event logging
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
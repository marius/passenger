#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  Phusion Passenger is a trademark of Hongli Lai & Ninh Bui.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'passenger/utils'

module Passenger

# This class maintains a collection of AbstractServer objects. One can add new
# AbstractServer objects, or look up existing ones via a key.
# AbstractServerCollection also automatically takes care of cleaning up
# AbstractServers that have been idle for too long.
#
# This class exists because both SpawnManager and Railz::FrameworkSpawner need this kind
# of functionality. SpawnManager maintains a collection of Railz::FrameworkSpawner
# and Railz::ApplicationSpawner objects, while Railz::FrameworkSpawner maintains a
# collection of Railz::ApplicationSpawner objects.
#
# This class is thread-safe.
class AbstractServerCollection
	attr_accessor :min_cleaning_interval
	attr_accessor :max_cleaning_interval
	attr_reader :cleaning_interval
	
	def initialize
		@collection = {}
		@lock = Mutex.new
		@cond = ConditionVariable.new
		@done = false
		@min_cleaning_interval = 20
		@max_cleaning_interval = 30 * 60
		@cleaning_interval = 2000000000
		@cleaner_thread = Thread.new do
			@lock.synchronize do
				cleaner_thread_main
			end
		end
	end
		
	# Lookup and returns an AbstractServer with the given key.
	#
	# If there is no AbstractSerer associated with the given key, then the given
	# block will be called. That block must return an AbstractServer object. Then,
	# that object will be stored in the collection, and returned.
	#
	# The block must adhere to the following rules:
	# - The block must not call any other methods on this AbstractServerCollection
	#   instance.
	# - It must set the 'max_idle_time' attribute on the AbstractServer.
	#   AbstractServerCollection's idle cleaning interval will be adapted to accomodate
	#   with this. Changing the value outside this block is not guaranteed to have any
	#   effect on the idle cleaning interval.
	#   A max_idle_time value of nil or 0 means the AbstractServer will never be idle cleaned.
	def lookup_or_add(key)
		raise ArgumentError, "cleanup() has already been called." if @done
		@lock.synchronize do
			server = @collection[key]
			if server
				return server
			else
				server = yield
				@collection[key] = server
				optimize_cleaning_interval
				@cond.signal
			end
		end
	end
	
	# Check whether there's an AbstractServer object associated with the given key.
	def has_key?(key)
		@lock.synchronize do
			return @collection.has_key?(key)
		end
	end
	
	# Deletes from the collection the AbstractServer that's associated with the
	# given key. If no such AbstractServer exists, nothing will happen.
	#
	# If the AbstractServer is started, then it will be stopped before deletion.
	def delete(key)
		raise ArgumentError, "cleanup() has already been called." if @done
		@lock.synchronize do
			server = @collection[key]
			if server
				if server.started?
					server.stop
				end
				@collection.delete(key)
				optimize_cleaning_interval
				@cond.signal
			end
		end
	end
	
	# Cleanup all resources used by this AbstractServerCollection. All AbstractServers
	# from the collection will be deleted. Each AbstractServer will be stopped, if
	# necessary. The background thread which removes idle AbstractServers will be stopped.
	#
	# After calling this method, this AbstractServerCollection object will become
	# unusable.
	#
	# This method is NOT thread-safe.
	def cleanup
		return if @done
		@lock.synchronize do
			@done = true
			@cond.signal
		end
		@cleaner_thread.join
		@lock.synchronize do
			@collection.each_value do |server|
				if server.started?
					server.stop
				end
			end
			@collection.clear
		end
	end

private
	def cleaner_thread_main
		while !@done
			if @cond.timed_wait(@lock, @cleaning_interval)
				next
			else
				current_time = Time.now
				keys_to_delete = nil
				@collection.each_pair do |key, server|
					if server.max_idle_time && server.max_idle_time != 0 && \
					   current_time - server.last_activity_time > server.max_idle_time
						keys_to_delete ||= []
						keys_to_delete << key
						if server.started?
							server.stop
						end
					end
				end
				if keys_to_delete
					keys_to_delete.each do |key|
						@collection.delete(key)
					end
					optimize_cleaning_interval
				end
			end
		end
	end
	
	def optimize_cleaning_interval
		smallest_max_idle_time = 2000000000
		@collection.each_value do |server|
			if server.max_idle_time && server.max_idle_time != 0 && \
			   server.max_idle_time < smallest_max_idle_time
				smallest_max_idle_time = server.max_idle_time
			end
		end
		
		# We add an extra 2 seconds because @cond.timed_wait()'s timer
		# may not be entirely accurate.
		@cleaning_interval = smallest_max_idle_time + 2
		if @cleaning_interval < @min_cleaning_interval
			# We don't want to waste CPU by checking too often, so
			# we put a lower bound on the cleaning interval.
			@cleaning_interval = @min_cleaning_interval
		elsif @cleaning_interval > @max_cleaning_interval
			# Suppose we have two AbstractServers, one with max_idle_time
			# of 59 minutes and the other with 60 minutes. If we cleaned up
			# the first one then we'd have to wait another 59 minutes before
			# cleaning up the second. That's obviously not desirable.
			#
			# There's probably a smarter way optimize the cleaning interval,
			# but for now, we just make sure the cleaning interval is never
			# larger than the given upper bound.
			@cleaning_interval = @max_cleaning_interval
		end
	end
end

end # module Passenger
# Copyright 2018 Google, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require 'securerandom'
require 'forwardable'

class EnumeratorQueue
  extend Forwardable
  def_delegators :@q, :push

  # @private
  def initialize sentinel
    @q = Queue.new
    @sentinel = sentinel
  end

  # @private
  def each_item
    return enum_for(:each_item) unless block_given?
    loop do
      r = @q.pop
      break if r.equal? @sentinel
      fail r if r.is_a? Exception
      yield r
    end
  end
end

def detect_intent_stream project_id:, session_id:, audio_file_path:,
                        language_code:
  # [START dialogflow_detect_intent_stream]
  # project_id = "Your Google Cloud project ID"
  # session_id = "mysession"
  # language_code = "en-US"
  
  require "google/cloud/dialogflow"
  require "monitor"

  session_client = Google::Cloud::Dialogflow::Sessions.new
  session = session_client.class.session_path project_id, session_id
  puts "Session path: #{session}"

  audio_config = { 
    audio_encoding: :AUDIO_ENCODING_LINEAR_16,
    sample_rate_hertz: 16000,
    language_code: language_code
  }
  query_input = { audio_config: audio_config }
  streaming_config = { session: session, query_input: query_input }

  # To signal the main thread when all responses have been processed
  completed = false

  # Use session_client as the sentinel to signal the end of queue
  request_queue  = EnumeratorQueue.new(session_client)

  # The first request needs to be the configuration.
  request_queue.push(streaming_config)

  # Consume the queue and process responses in a separate thread
  Thread.new do
    session_client.streaming_detect_intent(request_queue.each_item).each do |response|
      if response.recognition_result
        puts "Intermediate transcript: #{response.recognition_result.transcript}"
      else
        # the last response has the actual query result
        query_result = response.query_result
        puts "=" * 20
        puts "Query text:        #{query_result.query_text}"
        puts "Intent detected:   #{query_result.intent.display_name}"
        puts "Intent confidence: #{query_result.intent_detection_confidence}"
        puts "Fulfillment text:  #{query_result.fulfillment_text}"
      end
    end
    completed = true
  end

  # While the main thread adds chunks of audio data to the queue
  begin
    audio_file = File.open(audio_file_path, 'rb')
      while true
        chunk = audio_file.read 4096
        break if not chunk
        request_queue.push({ input_audio: chunk})
        sleep 0.5
      end
  ensure
    audio_file.close
    request_queue.push(session_client)
  end

  # Do not exit the main thread until the processing thread is completed
  while not completed
    sleep 1
  end
  # [END dialogflow_detect_intent_stream]
end


if __FILE__ == $PROGRAM_NAME
  project_id = ENV["GOOGLE_CLOUD_PROJECT"]
  session_id = SecureRandom.uuid
  language_code = 'en-US'

  audio_file_path = ARGV.shift

  if audio_file_path
    detect_intent_stream project_id: project_id, session_id: session_id,
                         audio_file_path: audio_file_path,
                         language_code:language_code
  else
    puts <<-usage
Usage: ruby detect_intent_stream.rb [audio_file_path]

Example:
  ruby detect_intent_stream.rb resources/book_a_room.wav

Environment variables:
  GOOGLE_CLOUD_PROJECT must be set to your Google Cloud project ID
    usage
  end
end
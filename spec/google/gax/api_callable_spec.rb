# Copyright 2016, Google Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#     * Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following disclaimer
# in the documentation and/or other materials provided with the
# distribution.
#     * Neither the name of Google Inc. nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'google/gax/api_callable'
require 'google/gax'

class CustomException < StandardError
  attr_reader :code

  def initialize(msg, code)
    super(msg)
    @code = code
  end
end

FAKE_STATUS_CODE_1 = :FAKE_STATUS_CODE_1
FAKE_STATUS_CODE_2 = :FAKE_STATUS_CODE_2

describe Google::Gax do
  CallSettings = Google::Gax::CallSettings

  describe 'create_api_call' do
    it 'calls api call' do
      settings = CallSettings.new
      deadline_arg = nil
      func = proc do |deadline: nil|
        deadline_arg = deadline
        42
      end
      my_callable = Google::Gax.create_api_call(func, settings)
      expect(my_callable.call(nil)).to eq(42)
      expect(deadline_arg).to be_a(Time)

      new_deadline = Time.now + 20
      options = Google::Gax::CallOptions.new(timeout: 20)
      expect(my_callable.call(nil, options)).to eq(42)
      expect(deadline_arg).to be_within(0.9).of(new_deadline)
    end
  end

  describe 'page streaming' do
    page_size = 3
    pages_to_stream = 5

    page_descriptor = Google::Gax::PageDescriptor.new('page_token',
                                                      'next_page_token', 'nums')
    settings = CallSettings.new(page_descriptor: page_descriptor)
    deadline_arg = nil
    func = proc do |request, deadline: nil|
      deadline_arg = deadline
      page_token = request['page_token']
      if page_token > 0 && page_token < page_size * pages_to_stream
        { 'nums' => (page_token...(page_token + page_size)),
          'next_page_token' => page_token + page_size }
      elsif page_token >= page_size * pages_to_stream
        { 'nums' => [] }
      else
        { 'nums' => 0...page_size, 'next_page_token' => page_size }
      end
    end

    it 'iterates over elements' do
      my_callable = Google::Gax.create_api_call(func, settings)
      expect(my_callable.call('page_token' => 0).to_a).to match_array(
        (0...(page_size * pages_to_stream))
      )
      expect(deadline_arg).to be_a(Time)
    end

    it 'offers interface for pages' do
      my_callable = Google::Gax.create_api_call(func, settings)
      stream = my_callable.call('page_token' => 0)
      page = stream.page
      expect(page.to_a).to eq((0...page_size).to_a)
      expect(page.next_page_token?).to be_truthy
      page = stream.next_page
      expect(page.to_a).to eq((page_size...(page_size * 2)).to_a)

      stream = my_callable.call('page_token' => 0)
      expect(stream.enum_for(:each_page).to_a.size).to eq(pages_to_stream + 1)
    end

    it 'starts from the specified page_token' do
      my_settings = settings.merge(Google::Gax::CallOptions.new(page_token: 3))
      my_callable = Google::Gax.create_api_call(func, my_settings)
      expect(my_callable.call({}).to_a).to match_array(
        3...(page_size * pages_to_stream)
      )
    end
  end

  describe 'failures without retry' do
    it 'simply fails' do
      settings = CallSettings.new(errors: [GRPC::Cancelled])
      deadline_arg = nil
      call_count = 0
      func = proc do |deadline: nil|
        deadline_arg = deadline
        call_count += 1
        raise GRPC::Cancelled, ''
      end
      my_callable = Google::Gax.create_api_call(func, settings)
      begin
        my_callable.call
        expect(true).to be false # should not reach to this line.
      rescue Google::Gax::GaxError => exc
        expect(exc.cause).to be_a(GRPC::Cancelled)
      end
      expect(deadline_arg).to be_a(Time)
      expect(call_count).to eq(1)
    end

    it 'does not wrap unknown errors' do
      settings = CallSettings.new
      deadline_arg = nil
      call_count = 0
      func = proc do |deadline: nil|
        deadline_arg = deadline
        call_count += 1
        raise CustomException.new('', FAKE_STATUS_CODE_1)
      end
      my_callable = Google::Gax.create_api_call(func, settings)
      expect { my_callable.call }.to raise_error(CustomException)
      expect(deadline_arg).to be_a(Time)
      expect(call_count).to eq(1)
    end
  end

  describe 'retryable' do
    RetryOptions = Google::Gax::RetryOptions
    BackoffSettings = Google::Gax::BackoffSettings

    retry_options = RetryOptions.new([FAKE_STATUS_CODE_1],
                                     BackoffSettings.new(0, 0, 0, 0, 0, 0, 1))
    settings = CallSettings.new(timeout: 0, retry_options: retry_options)

    it 'retries the API call' do
      time_now = Time.now
      allow(Time).to receive(:now).and_return(time_now)

      to_attempt = 3

      deadline_arg = nil
      func = proc do |deadline: nil|
        deadline_arg = deadline
        to_attempt -= 1
        raise CustomException.new('', FAKE_STATUS_CODE_1) if to_attempt > 0
        1729
      end
      my_callable = Google::Gax.create_api_call(func, settings)
      expect(my_callable.call).to eq(1729)
      expect(to_attempt).to eq(0)
      expect(deadline_arg).to be_a(Time)
    end

    it 'doesn\'t retry if no codes' do
      retry_options = RetryOptions.new([],
                                       BackoffSettings.new(1, 2, 3, 4, 5, 6, 7))

      call_count = 0
      func = proc do
        call_count += 1
        raise CustomException.new('', FAKE_STATUS_CODE_1)
      end
      my_callable = Google::Gax.create_api_call(
        func, CallSettings.new(timeout: 0, retry_options: retry_options)
      )
      expect { my_callable.call }.to raise_error(Google::Gax::RetryError)
      expect(call_count).to eq(1)
    end

    it 'aborts retries' do
      func = proc { raise CustomException.new('', FAKE_STATUS_CODE_1) }
      my_callable = Google::Gax.create_api_call(func, settings)
      begin
        my_callable.call
        expect(true).to be false # should not reach to this line.
      rescue Google::Gax::RetryError => exc
        expect(exc.cause).to be_a(CustomException)
      end
    end

    it 'times out' do
      to_attempt = 3
      call_count = 0

      time_now = Time.now
      # Time.now will be called twice for each API call (one in set_timeout_arg
      # and the other in retryable). It returns time_now for to_attempt * 2
      # times (which allows retrying), and then finally returns time_now + 2
      # to exceed the deadline.
      allow(Time).to receive(:now).exactly(to_attempt * 2 + 1).times.and_return(
        *([time_now] * to_attempt * 2 + [time_now + 2])
      )

      deadline_arg = nil
      func = proc do |deadline: nil|
        deadline_arg = deadline
        call_count += 1
        raise CustomException.new('', FAKE_STATUS_CODE_1)
      end

      my_callable = Google::Gax.create_api_call(func, settings)
      begin
        my_callable.call
        expect(true).to be false # should not reach to this line.
      rescue Google::Gax::RetryError => exc
        expect(exc.cause).to be_a(CustomException)
      end
      expect(deadline_arg).to eq(time_now)
      expect(call_count).to eq(to_attempt)
    end

    it 'aborts on unexpected exception' do
      call_count = 0
      func = proc do
        call_count += 1
        raise CustomException.new('', FAKE_STATUS_CODE_2)
      end
      my_callable = Google::Gax.create_api_call(func, settings)
      expect { my_callable.call }.to raise_error(Google::Gax::RetryError)
      expect(call_count).to eq(1)
    end

    it 'does not retry even when no responses' do
      func = proc { nil }
      my_callable = Google::Gax.create_api_call(func, settings)
      expect(my_callable.call).to be_nil
    end

    it 'retries with exponential backoff' do
      time_now = Time.now
      start_time = time_now
      incr_time = proc { |secs| time_now += secs }
      call_count = 0
      func = proc do |_, deadline: nil|
        call_count += 1
        incr_time.call(deadline - time_now)
        raise CustomException.new(deadline.to_s, FAKE_STATUS_CODE_1)
      end

      allow(Time).to receive(:now) { time_now }
      allow(Kernel).to receive(:sleep) { |secs| incr_time.call(secs) }
      backoff = BackoffSettings.new(3, 2, 24, 5, 2, 80, 2500)
      retry_options = RetryOptions.new([FAKE_STATUS_CODE_1], backoff)
      my_callable = Google::Gax.create_api_call(
        func, CallSettings.new(timeout: 0, retry_options: retry_options)
      )

      begin
        my_callable.call(0)
        expect(true).to be false # should not reach to this line.
      rescue Google::Gax::RetryError => exc
        expect(exc.cause).to be_a(CustomException)
      end
      expect(time_now - start_time).to be >= (
        backoff.total_timeout_millis / 1000.0)

      calls_lower_bound = backoff.total_timeout_millis / (
        backoff.max_retry_delay_millis + backoff.max_rpc_timeout_millis)
      calls_upper_bound = (backoff.total_timeout_millis /
                           backoff.initial_retry_delay_millis)
      expect(call_count).to be > calls_lower_bound
      expect(call_count).to be < calls_upper_bound
    end
  end
end

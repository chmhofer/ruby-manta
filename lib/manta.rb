# Copyright (c) 2012, Joyent, Inc. All rights reserved.
#
# ruby-manta is a simple low-abstraction layer which communicates with Joyent's
# Manta service.
#
# Manta is an HTTP-accessible object store supporting UNIX-based map-reduce
# jobs. Through ruby-manta a programmer can save/overwrite/delete objects
# stored on a Manta service, or run map-reduce jobs over those objects.
#
# ruby-manta should be thread-safe, and supports pooling of keep-alive
# connections to the same server (through HTTPClient). It only relies on the
# standard library and a pure Ruby HTTP client, so it should work anywhere.
#
# For more information about Manta and general ruby-manta usage, please see
# README.md.



require 'openssl'
require 'net/ssh'
require 'httpclient'
require 'base64'
require 'date'
require 'json'
require 'cgi'



class Manta
  DEFAULT_ATTEMPTS        = 3
  DEFAULT_CONNECT_TIMEOUT = 5
  DEFAULT_SEND_TIMEOUT    = 60
  DEFAULT_RECEIVE_TIMEOUT = 60
  MAX_LIMIT        = 1000
  LIB_VERSION      = '1.0.0'
  HTTP_AGENT       = "ruby-manta/#{LIB_VERSION} (#{RUBY_PLATFORM}; #{OpenSSL::OPENSSL_VERSION}) ruby/#{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}"
  HTTP_SIGNATURE   = 'Signature keyId="/%s/keys/%s",algorithm="%s" %s'
  ERROR_CLASSES    = [ 'AuthorizationFailed', 'AuthorizationSchemeNotAllowed',
                       'ConcurrentRequest', 'ContentLengthRequired',
                       'ContentMD5Mismatch', 'DirectoryDoesNotExist',
                       'DirectoryNotEmpty', 'EntityAlreadyExists',
                       'InternalError', 'InvalidAuthenticationToken',
                       'InvalidDurabilityLevel', 'InvalidJob',
                       'InvalidJobState', 'InvalidKeyId', 'InvalidLink',
                       'InvalidQueryStringAuthentication', 'InvalidSignature',
                       'JobNotFound', 'KeyDoesNotExist', 'LinkNotObject',
                       'LocationRequired', 'NotAcceptable', 'NotEnoughSpace',
                       'OperationNotAllowedOnDirectory',
                       'OperationNotAllowedOnRootDirectory',
                       'ParentNotDirectory', 'ResourceNotFound',
                       'SecureTransportRequired', 'ServiceUnavailable',
                       'SourceObjectNotFound', 'UploadTimeout',
                       'UserDoesNotExist',
                       # and errors that are specific to this class:
                       'CorruptResultError', 'UnknownError',
                       'UnsupportedKeyError' ]



  # Initialize a Manta instance.
  def initialize(client, host, user, key_id, priv_key, opts = {})
    raise unless client.is_a? HTTPClient
    raise unless host =~ /^https{0,1}:\/\/.*[^\/]/
    raise unless user.is_a?(String) && user.size > 0
    raise unless key_id
    raise unless priv_key.is_a?(OpenSSL::PKey::RSA) ||
                 priv_key.is_a?(OpenSSL::PKey::DSA)

    if priv_key.class == OpenSSL::PKey::RSA
      @digest      = OpenSSL::Digest::SHA1.new
      @digest_name = 'rsa-sha1'
    else
      @digest      = OpenSSL::Digest::DSS1.new
      @digest_name = 'dsa-sha1'
    end

    @attempts = opts[:attempts] || DEFAULT_ATTEMPTS
    raise unless @attempts > 0

    @client    = client
    @host      = host
    @user      = user
    @key_id    = key_id
    @priv_key  = priv_key

    @obj_match = Regexp.new('^/' + user + '/(?:stor|public)')
    @job_match = Regexp.new('^/' + user + '/jobs/.+')
    @job_base  = '/' + user + '/jobs'
  end



  # Uploads object data to Manta to the given path, along with a computed MD5
  # hash.
  #
  # The path must start with /<user>/stor or /<user/public. Data can be any
  # sequence of octets. The HTTP Content-Type stored on Manta can be set
  # with an optional :content_type argument; the default is
  # application/octet-stream. The number of distributed replicates of an object
  # stored in Manta can be set with an optional :durability_level; the default
  # is 2.
  #
  # Returns true along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def put_object(obj_path, data, opts = {})
    url     = obj_url(obj_path)
    headers = gen_headers(data)

    durability_level = opts[:durability_level]
    if durability_level
      raise unless durability_level > 0
      headers.push([ 'Durability-Level', durability_level ])
    end

    content_type = opts[:content_type]
    if content_type
      raise unless content_type.is_a? String
      headers.push([ 'Content-Type', content_type ])
    end

    attempt(opts[:attempts]) do
      result = @client.put(url, data, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Get an object from Manta at a given path, and checks it's uncorrupted.
  #
  # The path must start with /<user>/stor or /<user/public and point at an
  # actual object. :head => true can optionally be passed in to do a HEAD
  # instead of a GET.
  #
  # Returns the retrieved data along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_object(obj_path, opts = {})
    url     = obj_url(obj_path)
    headers = gen_headers()

    attempt(opts[:attempts]) do
      method = opts[:head] ? :head : :get
      result = @client.send(method, url, nil, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 200
	return true, result.headers if method == :head

        sent_md5     = result.headers['Content-MD5']
        received_md5 = OpenSSL::Digest::MD5.base64digest(result.body)
        raise CorruptResultError if sent_md5 != received_md5

        return result.body, result.headers
      end

      raise_error(result)
    end
  end



  # Deletes an object off Manta at a given path.
  #
  # The path must start with /<user>/stor or /<user/public and point at an
  # actual object.
  #
  # Returns true along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def delete_object(obj_path, opts = {})
    url     = obj_url(obj_path)
    headers = gen_headers()

    attempt(opts[:attempts]) do
      result = @client.delete(url, nil, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Creates a directory on Manta at a given path.
  #
  # The path must start with /<user>/stor or /<user/public.
  #
  # Returns true along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def put_directory(dir_path, opts = {})
    url = obj_url(dir_path)
    headers = gen_headers()
    headers.push([ 'Content-Type', 'application/json; type=directory' ])

    attempt(opts[:attempts]) do
      result = @client.put(url, nil, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Gets a lexicographically sorted directory listing on Manta at a given path,
  #
  # The path must start with /<user>/stor or /<user/public and point at an
  # actual directory. :limit optionally changes the maximum number of entries;
  # the default is 1000. If given :marker, an object path, returned directory
  # entries will begin from that point. :head => true can optionally be passed
  # in to do a HEAD instead of a GET.
  #
  # Returns an array of hash objects, each object representing a directory
  # entry. Also returns the received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def list_directory(dir_path, opts = {})
    url     = obj_url(dir_path)
    headers = gen_headers()
    query_parameters = {}

    limit = opts[:limit] || MAX_LIMIT
    raise unless 0 < limit && limit <= MAX_LIMIT
    query_parameters[:limit] = limit

    marker = opts[:marker]
    if marker
      raise unless marker.is_a? String
      query_parameters[:marker] = marker
    end

    attempt(opts[:attempts]) do
      method = opts[:head] ? :head : :get
      result = @client.send(method, url, query_parameters, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 200
        raise unless result.headers['Content-Type'] ==
                     'application/x-json-stream; type=directory'

	return true, result.headers if method == :head

        json_chunks = result.body.split("\r\n")

        sent_num_entries = result.headers['Result-Set-Size'].to_i
        if (json_chunks.size != sent_num_entries && json_chunks.size != limit) ||
           json_chunks.size > limit
          raise CorruptResultError
        end

        dir_entries = json_chunks.map { |i| JSON.parse(i) }

        return dir_entries, result.headers
      end

      raise_error(result)
    end
  end



  # Removes a directory from Manta at a given path.
  #
  # The path must start with /<user>/stor or /<user/public and point at an
  # actual object.
  #
  # Returns true along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def delete_directory(dir_path, opts = {})
    url     = obj_url(dir_path)
    headers = gen_headers()

    attempt(opts[:attempts]) do
      result = @client.delete(url, nil, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Creates a link from on object in Manta at a given path to a different path.
  #
  # Both paths should start with /<user>/stor or /<user/public.
  #
  # Returns true along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def put_link(dir_path, link_path, opts = {})
    headers = gen_headers()
    headers.push([ 'Content-Type', 'application/json; type=link' ],
                 [ 'Location',     obj_url(dir_path)             ])

    attempt(opts[:attempts]) do
      result = @client.put(obj_url(link_path), nil, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Creates a job in Manta.
  #
  # The job must be a hash, containing at minimum a :phases key. See README.md
  # or the Manta docs to see the format and options for setting up a job on
  # Manta; this method effectively just converts the job hash to JSON and sends
  # to the Manta service.
  #
  # Returns the path for the new job, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def create_job(job, opts = {})
    raise unless job[:phases] || job['phases']

    headers = gen_headers()
    headers.push([ 'Content-Type', 'application/json; type=job' ])
    data = job.to_json

    attempt(opts[:attempts]) do
      result = @client.post(job_url(), data, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 201
        location = result.headers['Location']
        raise unless location

        return location, result.headers
      end

      raise_error(result)
    end
  end



  # Gets various information about a job in Manta at a given path.
  #
  # The path must start with /<user>/jobs and point at an actual job.
  # :head => true can optionally be passed in to do a HEAD instead of a GET.
  #
  # Returns a hash with job information, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_job(job_path, opts = {})
    url     = job_url(job_path)
    headers = gen_headers()

    attempt(opts[:attempts]) do
      method = opts[:head] ? :head : :get
      result = @client.send(method, url, nil, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 200
        raise unless result.headers['Content-Type'] == 'application/json'

	return true, result.headers if method == :head

        job = JSON.parse(result.body)
        return job, result.headers
      end

      raise_error(result)
    end
  end



  # Gets errors that occured during the execution of a job in Manta at a given
  # path.
  #
  # The path must start with /<user>/jobs and point at an actual job.
  # :head => true can optionally be passed in to do a HEAD instead of a GET.
  #
  # Returns an array of hashes, each hash containing information about an
  # error; this information is best-effort by Manta, so it may not be complete.
  # Also returns received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_job_errors(job_path, opts = {})
    url     = job_url(job_path, '/err')
    headers = gen_headers()

    attempt(opts[:attempts]) do
      method = opts[:head] ? :head : :get
      result = @client.send(method, url, nil, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 200
        raise unless result.headers['Content-Type'] ==
                     'application/x-json-stream; type=job-error'

	return true, result.headers if method == :head

        json_chunks = result.body.split("\r\n")
#        sent_num_entries = result.headers['Result-Set-Size']
#        raise CorruptResultError if json_chunks.size != sent_num_entries.to_i

        errors = json_chunks.map { |i| JSON.parse(i) }

        return errors, result.headers
      end

      raise_error(result)
    end
  end



  # Cancels a running job in Manta at a given path.
  #
  # The path must start with /<user>/jobs and point at an actual job.
  #
  # Returns a hash with job information, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def cancel_job(job_path, opts = {})
    url     = job_url(job_path, '/cancel')
    headers = gen_headers()

    attempt(opts[:attempts]) do
      result = @client.post(url, nil, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Adds objects for a running job in Manta to process.
  #
  # The job_path must start with /<user>/jobs and point at an actual running
  # job. The obj_paths must be an array of paths, starting with /<user>/stor
  # or /<user>/public, pointing at actual objects.
  #
  # Returns true, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def add_job_keys(job_path, obj_paths, opts = {})
    url = job_url(job_path, '/in')
    headers = gen_headers()
    headers.push([ 'Content-Type', 'text/plain' ])

    data = obj_paths.map { |p| '/' + @user + '/stor' + p }.
                     join("\n")

    attempt(opts[:attempts]) do
      result = @client.post(url, data, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Inform Manta that no more objects will be added for processing by a job,
  # and that the job should finish all phases and terminate.
  #
  # The job_path must start with /<user>/jobs and point at an actual running
  # job.
  #
  # Returns true, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def end_job_input(job_path, opts = {})
    url     = job_url(job_path, '/in/end')
    headers = gen_headers()

    attempt(opts[:attempts]) do
      result = @client.post(url, nil, headers)
      raise unless result.is_a? HTTP::Message

      return true, result.headers if result.status == 204
      raise_error(result)
    end
  end



  # Get a list of objects that have been given to a Manta job for processing.
  #
  # The job_path must start with /<user>/jobs and point at an actual running
  # job.
  #
  # Returns an array of object paths, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_job_input(job_path, opts = {})
    get_job_state_streams(:in, job_path, opts)
  end



  # Get a list of objects that contain the intermediate results of a running
  # Manta job.
  #
  # The job_path must start with /<user>/jobs and point at an actual running
  # job.
  #
  # Returns an array of object paths, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_job_output(job_path, opts = {})
    get_job_state_streams(:out, job_path, opts)
  end



  # Get a list of objects that had failures during processing in a Manta job.
  #
  # The job_path must start with /<user>/jobs and point at an actual running
  # job.
  #
  # Returns an array of object paths, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_job_failures(job_path, opts = {})
    get_job_state_streams(:fail, job_path, opts)
  end



  # Get lists of Manta jobs.
  #
  # The state indicates which kind of jobs to return. :running is for jobs
  # that are currently processing, :done and :all should be obvious. Be careful
  # of the latter two if you've run a lot of jobs -- the list could be quite
  # long.
  #
  # Returns an array of hashes, each hash containing information about a job.
  # Also returns received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def list_jobs(state, opts = {})
    raise unless [:all, :running, :done].include? state
    state = nil if state == :all

    headers = gen_headers()

    attempt(opts[:attempts]) do
#      method = opts[:head] ? :head : :get
      method = :get # until added to Manta service
      result = @client.send(method, job_url(), { :state => state }, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 200
        raise unless result.headers['Content-Type'] ==
                     'application/x-json-stream; type=job'

	return true, result.headers if method == :head

        json_chunks      = result.body.split("\r\n")
        sent_num_entries = result.headers['Result-Set-Size']
        raise CorruptResultError if json_chunks.size != sent_num_entries.to_i

        job_entries = json_chunks.map { |i| JSON.parse(i) }

        return job_entries, result.headers
      end

      raise_error(result)
    end
  end



  # Processes a private key and returns data useful for creating multiple
  # Manta (the class) instances. 
  #
  # priv_key_data is data read directly from an SSH private key (i.e. RFC 4716
  # format). It can also accept several optional args: :connect_timeout,
  # :send_timeout, :receive_timeout, and :disable_ssl_verification. The
  # timeouts are in seconds. The options affect all users of the returned
  # HTTP client object.
  #
  # Returns an HTTP client, fingerprint, and private key.
  #
  # Will throw an exception if given a key whose format it doesn't understand.
  def self.prepare(priv_key_data, opts = {})
    algo = if priv_key_data =~ /BEGIN RSA/
             OpenSSL::PKey::RSA
           elsif priv_key_data =~ /BEGIN DSA/
             OpenSSL::PKey::DSA
           else
             raise UnsupportedKeyError
           end

    priv_key    = algo.new(priv_key_data)
    fingerprint = OpenSSL::Digest::MD5.hexdigest(priv_key.to_blob).
                                       scan(/../).join(':')

    client = HTTPClient.new
    client.connect_timeout = opts[:connect_timeout] || DEFAULT_CONNECT_TIMEOUT
    client.send_timeout    = opts[:send_timeout   ] || DEFAULT_SEND_TIMEOUT
    client.receive_timeout = opts[:receive_timeout] || DEFAULT_RECEIVE_TIMEOUT
    client.ssl_config.verify_mode = nil if opts[:disable_ssl_verification]

    return client, fingerprint, priv_key
  end



  # Generates a signed URL which can be used by unauthenticated users to
  # make a request to Manta at the given path. This is typically used to GET
  # an object.
  #
  # expires is a Time object or integer representing time after epoch; this
  # determines how long the signed URL will be valid for. The method is the HTTP
  # method (:get, :put, :post, :delete) the signed URL is allowed to be used
  # for. The path must start with /<user>/stor. Lastly, the optional args is an
  # array containing pairs of query args that will be appended at the end of
  # the URL.
  #
  # The returned URL is signed, and can be used either over HTTP or HTTPS until
  # it reaches the expiry date.
  def gen_signed_url(expires, method, path, args=[])
    raise unless [:get, :put, :post, :delete].include? method
    raise unless path =~ @obj_match

    key_id = '/%s/keys/%s' % [@user, @key_id]

    args.push([ 'expires',   expires.to_i ])
    args.push([ 'algorithm', @digest_name ])
    args.push([ 'keyId',     key_id       ])

    encoded_args = args.sort.map do |key, val|
      # to comply with RFC 3986
      CGI.escape(key.to_s) + '=' + CGI.escape(val.to_s)
    end.join('&')

    method = method.to_s.upcase
    host   = @host.split('/').last

    plaintext = "#{method}\n#{host}\n#{path}\n#{encoded_args}"
    signature = @priv_key.sign(@digest, plaintext)
    encoded_signature = CGI.escape(Base64.strict_encode64(signature))

    host + path + '?' + encoded_args + '&signature=' + encoded_signature
  end



  # Create some Manta error classes
  class MantaError < StandardError; end
  for class_name in ERROR_CLASSES
    Manta.const_set(class_name, Class.new(MantaError))
  end



  # ---------------------------------------------------------------------------
  protected



  # Fetch lists of objects that have a given status.
  #
  # type takes one of three values (:in, :out, fail), path must start with
  # /<user>/jobs and point at an actual job.
  #
  # Returns an array of object paths, along with received HTTP headers.
  #
  # If there was an unrecoverable error, throws an exception. On connection or
  # corruption errors, more attempts will be made; the number of attempts can
  # be altered by passing in :attempts.
  def get_job_state_streams(type, path, opts)
    raise unless [:in, :out, :fail].include? type 

    url     = job_url(path, type.to_s)
    headers = gen_headers()

    attempt(opts[:attempts]) do
      #method = opts[:head] ? :head : :get
      method = :get # until added to Manta service
      result = @client.send(method, url, nil, headers)
      raise unless result.is_a? HTTP::Message

      if result.status == 200
        raise unless result.headers['Content-Type'] == 'text/plain'

	return true, result.headers if method == :head

        paths = result.body.split("\n")
#        sent_num_entries = result.headers['Result-Set-Size']
#        raise CorruptResultError if paths.size != sent_num_entries.to_i

        return paths, result.headers
      end

      raise_error(result)
    end
  end



  # Returns a full URL for a given path to an object.
  def obj_url(path)
    raise unless path =~ @obj_match
    @host + path
  end



  # Returns a full URL for a given path to a job.
  def job_url(*args)
    path = if args.size == 0
             @job_base
           else
             raise unless args.first =~ @job_match
             args.join('/')
           end

    @host + path
  end



  # Executes a block. If there is a connection- or corruption-related exception
  # the block will be reexecuted up to the `tries' argument. It will sleep
  # for an exponentially-increasing number of seconds between retries.
  def attempt(tries, &blk)
    if tries
      raise unless tries > 0
    else
      tries ||= @attempts
    end

    attempt = 1

    while true
      begin
        return yield blk
      rescue Errno::ECONNREFUSED, HTTPClient::TimeoutError,
             CorruptResultError => e
        raise e if attempt == tries
        sleep 2 ** attempt
        attempt += 1
      end
    end
  end



  # Creates headers to be given to the HTTP client and sent to the Manta
  # service. The most important is the Authorization header, without which
  # none of this class would work.
  def gen_headers(data = nil)
    now = Time.now.httpdate
    sig = gen_signature(now)

    headers = [[ 'Date',           now        ],
               [ 'Authorization',  sig        ],
               [ 'User-Agent',     HTTP_AGENT ],
               [ 'Accept-Version', '~1.0'     ]]

    if data
      md5 = OpenSSL::Digest::MD5.base64digest(data)
      headers.push([ 'Content-MD5', md5 ])
    end

    return headers
  end



  # Given a chunk of data, creates an HTTP signature which the Manta service
  # understands and uses for authentication.
  def gen_signature(data)
    raise unless data

    sig = @priv_key.sign(@digest, data)
    base64sig = Base64.strict_encode64(sig)

    return HTTP_SIGNATURE % [@user, @key_id, @digest_name, base64sig]
  end



  # Raises an appropriate exception given the HTTP response. If a 40* is
  # returned, attempts to look up an appropriate error class and raise,
  # otherwise raises an UnknownError.
  def raise_error(result)
    raise unless result.is_a? HTTP::Message

    if result.status < 400 || result.status > 499 || result.body == ''
      raise UnknownError, result.status.to_s + ': ' + result.body
    end

    err   = JSON.parse(result.body)
    klass = Manta.const_get err['code']
    raise klass, err['message']
  rescue NameError, JSON::ParserError
    raise UnknownError, result.status.to_s + ': ' + result.body
  end
end

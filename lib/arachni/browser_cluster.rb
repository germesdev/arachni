=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

require 'monitor'

module Arachni

# Real browser driver providing DOM/JS/AJAX support.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
class BrowserCluster
    include UI::Output
    include Utilities

    personalize_output

    # {BrowserCluster} error namespace.
    #
    # All {BrowserCluster} errors inherit from and live under it.
    #
    # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
    class Error < Arachni::Error

        # Raised when a method is called after the {BrowserCluster} has been
        # {BrowserCluster#shutdown}.
        #
        # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
        class AlreadyShutdown < Error
        end

        # Raised when a given {Job} could not be found.
        #
        # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
        class JobNotFound < Error
        end
    end

    lib = Options.paths.lib
    require lib + 'browser_cluster/worker'
    require lib + 'browser_cluster/job'

    # Load all job types.
    Dir[lib + 'browser_cluster/jobs/*'].each { |j| require j }

    # Holds {BrowserCluster} {Job} types.
    #
    # @see BrowserCluster#queue
    #
    # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
    module Jobs
    end

    DEFAULT_OPTIONS = {
        # Amount of Browsers to keep in the pool and put to work. 6 seems to
        # be the magic number, 1 to go over all elements and generate the workload
        # and 5 to pop the work from the queue and get to it.
        #
        # It's diminishing returns past that point, even with more workload
        # generators and more workers.
        pool_size:    6,

        # Lifetime of each Browser counted in pages.
        time_to_live: 10
    }

    # @return   [Integer]   Amount of browser instances in the pool.
    attr_reader :pool_size

    # @return   [Hash<String, Integer>]
    #   List of crawled URLs with their HTTP codes.
    attr_reader :sitemap

    # @return   [String]
    #   Javascript token used to namespace the custom JS environment.
    attr_reader :javascript_token

    # @return   [Array<Worker>]
    attr_reader :workers

    # @param    [Hash]  options
    # @option   options [Integer]   :pool_size (5)
    #   Amount of {RPC::Server::Browser browsers} to add to the pool.
    # @option   options [Integer]   :time_to_live (10)
    #   Restricts each browser's lifetime to the given amount of pages.
    #   When that number is exceeded the current process is killed and a new
    #   one is pushed to the pool. Helps prevent memory leak issues.
    #
    # @raise    ArgumentError   On missing `:handler` option.
    def initialize( options = {} )
        DEFAULT_OPTIONS.merge( options ).each do |k, v|
            begin
                send( "#{k}=", try_dup( v ) )
            rescue NoMethodError
                instance_variable_set( "@#{k}".to_sym, v )
            end
        end

        # Used to sync operations between workers per Job#id.
        @skip = {}

        # Callbacks for each job per Job#id. We need to keep track of this
        # here because jobs are serialized and offloaded to disk and thus can't
        # contain callbacks.
        @job_callbacks = {}

        # Keeps track of the amount of pending jobs distributed across the
        # cluster, by Job#id. Once a job's count reaches 0, it's passed to
        # #job_done.
        @pending_jobs = Hash.new(0)
        @pending_job_counter = 0

        # Jobs are off-loaded to disk.
        @jobs = Support::Database::Queue.new

        @sitemap     = {}
        @mutex       = Monitor.new
        @done_signal = Queue.new
        @workers     = []

        @javascript_token = Utilities.generate_token

        initialize_workers
    end

    # @note Operates in non-blocking mode.
    #
    # @param    [Block] block
    #   Block to which to pass a {Worker} as soon as one is available.
    def with_browser( &block )
        queue( Jobs::BrowserProvider.new, &block )
    end

    # @param    [Job]  job
    # @param    [Block]  block Callback to be passed the {Job::Result}.
    #
    # @raise    [AlreadyShutdown]
    # @raise    [Job::Error::AlreadyDone]
    def queue( job, &block )
        fail_if_shutdown
        fail_if_job_done job

        @done_signal.clear

        synchronize do
            @pending_job_counter  += 1
            @pending_jobs[job.id] += 1
            @job_callbacks[job.id] = block if block

            if !@job_callbacks[job.id]
                fail ArgumentError, "No callback set for job ID #{job.id}."
            end

            @jobs << job
        end

        nil
    end

    # @param    [Page, String, HTTP::Response]  resource
    #   Resource to explore, if given a `String` it will be treated it as a URL
    #   and will be loaded.
    # @param    [Hash]  options See {Jobs::ResourceExploration} accessors.
    # @param    [Block]  block Callback to be passed the {Job::Result}.
    #
    # @see Jobs::ResourceExploration
    # @see #queue
    def explore( resource, options = {}, &block )
        queue(
            Jobs::ResourceExploration.new( options.merge( resource: resource ) ),
            &block
        )
    end

    # @param    [Page, String, HTTP::Response] resource
    #   Resource to load and whose environment to trace, if given a `String` it
    #   will be treated it as a URL and will be loaded.
    # @param    [Hash]  options See {Jobs::TaintTrace} accessors.
    # @param    [Block]  block Callback to be passed the {Job::Result}.
    #
    # @see Jobs::TaintTrace
    # @see #queue
    def trace_taint( resource, options = {}, &block )
        queue( Jobs::TaintTrace.new( options.merge( resource: resource ) ), &block )
    end

    # @param    [Job]  job
    #   Job to mark as done. Will remove any callbacks and associated {#skip} state.
    def job_done( job )
        synchronize do
            if !job.never_ending?
                @skip.delete job.id
                @job_callbacks.delete job.id
            end

            @pending_job_counter -= @pending_jobs[job.id]
            @pending_jobs[job.id] = 0

            if @pending_job_counter <= 0
                @pending_job_counter = 0
                @done_signal << nil
            end
        end

        true
    end

    # @param    [Job]  job
    #
    # @return   [Bool]
    #   `true` if the `job` has been marked as finished, `false` otherwise.
    #
    # @raise    [Error::JobNotFound]  Raised when `job` could not be found.
    def job_done?( job, fail_if_not_found = true )
        return false if job.never_ending?

        synchronize do
            fail_if_job_not_found job if fail_if_not_found
            return false if !@pending_jobs.include?( job.id )
            @pending_jobs[job.id] == 0
        end
    end

    # @param    [Job::Result]  result
    #
    # @private
    def handle_job_result( result )
        return if job_done? result.job
        fail_if_shutdown

        synchronize do
            exception_jail( false ) do
                @job_callbacks[result.job.id].call result
            end
        end

        nil
    end

    # @return   [Bool]
    #   `true` if there are no resources to analyze and no running workers.
    def done?
        fail_if_shutdown
        synchronize { @pending_job_counter == 0 }
    end

    # Blocks until all resources have been analyzed.
    def wait
        fail_if_shutdown
        @done_signal.pop if !done?
        self
    end

    # Shuts the cluster down.
    def shutdown
        @shutdown = true

        # Clear the jobs -- don't forget this, it also remove the disk files for
        # the contained items.
        @jobs.clear

        # Kill the browsers.
        @workers.each(&:shutdown)

        true
    end

    # @return    [Job]  Pops a job from the queue.
    # @see #queue
    #
    # @private
    def pop
        job = @jobs.pop
        job = pop if job_done? job
        job
    end

    # Used to sync operations between browser workers.
    #
    # @param    [Integer]   job_id  Job ID.
    # @param    [String]    action  Should the given action be skipped?
    #
    # @raise    [Error::JobNotFound]  Raised when `job` could not be found.
    #
    # @private
    def skip?( job_id, action )
        synchronize do
            skip_lookup_for( job_id ).include? action
        end
    end

    # Used to sync operations between browser workers.
    #
    # @param    [Integer]   job_id  Job ID.
    # @param    [String]    action  Action to skip in the future.
    #
    # @private
    def skip( job_id, action )
        synchronize { skip_lookup_for( job_id ) << action }
    end

    # @private
    def push_to_sitemap( url, code )
        synchronize { @sitemap[url] = code }
    end

    # @private
    def update_skip_lookup_for( id, lookups )
        synchronize { skip_lookup_for( id ).merge lookups }
    end

    # @private
    def skip_lookup_for( id )
        synchronize do
            @skip[id] ||= Support::LookUp::HashSet.new( hasher: :persistent_hash )
        end
    end

    # @private
    def decrease_pending_job( job )
        synchronize do
            @pending_job_counter  -= 1
            @pending_jobs[job.id] -= 1
            job_done( job ) if @pending_jobs[job.id] <= 0
        end
    end

    # @private
    def callback_for( job )
        @job_callbacks[job.id]
    end

    private

    def fail_if_shutdown
        fail Error::AlreadyShutdown, 'Cluster has been shut down.' if @shutdown
    end

    def fail_if_job_done( job )
        return if !job_done?( job, false )
        fail Job::Error::AlreadyDone, 'Job has been marked as done.'
    end

    def fail_if_job_not_found( job )
        return if @pending_jobs.include?( job.id ) || @job_callbacks.include?( job.id )
        fail Error::JobNotFound, 'Job could not be found.'
    end

    def synchronize( &block )
        @mutex.synchronize( &block )
    end

    def initialize_workers
        print_status "Initializing #{pool_size} browsers..."

        pool_size.times do
            @workers << Worker.new(
                javascript_token: @javascript_token,
                master:           self
            )
        end

        print_status "Initialization complete with #{@workers.size} browsers in the pool."
    end

end
end

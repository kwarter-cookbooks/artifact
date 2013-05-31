class Chef
  module Artifact
    DATA_BAG = "artifact".freeze
    WILDCARD_DATABAG_ITEM = "_wildcard".freeze

    module File

      # Returns true if the given file is a symlink.
      # 
      # @param  path [String] the path to the file to test
      # 
      # @return [Boolean]
      def symlink?(path)
        if windows?
          require 'chef/win32/file'
          return Chef::ReservedNames::Win32::File.symlink?(path)
        end
        ::File.symlink?(path)        
      end

      # Returns the value of the readlink method.
      # 
      # @param  path [String] the path to a symlink
      # 
      # @return [String] the path that the symlink points to
      def readlink(path)
        if windows?
          require 'chef/win32/file'
          return Chef::ReservedNames::Win32::File.readlink(path)
        end
        ::File.readlink(path)
      end

      # Generates a command to execute that either uses the Unix cp
      # command or the Windows copy command. 
      #
      # @param  source [String] the file to copy
      # @param  destination [String] the path to copy the source to
      # 
      # @return [String] a useable command to copy a file
      def copy_command_for(source, destination)
        if windows?
          %Q{copy "#{source}" "#{destination}"}.gsub(::File::SEPARATOR, ::File::ALT_SEPARATOR)
        else
         "cp -r #{source} #{destination}"
        end
      end

      # @return [Fixnum or nil]
      def windows?
        Chef::Platform.windows?
      end
    end

    class << self
      include Chef::Artifact::File

      # Loads the Nexus encrypted data bag item and returns credentials
      # for the environment or for a default key.
      #
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [Chef::DataBagItem] the data bag item
      def nexus_config_for(node)
        data_bag_item = if Chef::Config[:solo]
          Chef::DataBagItem.load(DATA_BAG, WILDCARD_DATABAG_ITEM)
        else
          encrypted_data_bag_for(node, DATA_BAG)
        end
        data_bag_item
      end

      # Uses the provided parameters to make a call to the data bag
      # configured Nexus server to have the server tell us what the
      # actual version number is when 'latest' is given.
      # 
      # @param  node [Chef::Node] the node
      # @param  artifact_location [String] a colon-separated Maven identifier string that represents the artifact
      # 
      # @example
      #   Chef::Artifact.get_actual_version(node, "com.myartifact:my-artifact:latest:tgz") => "2.0.5"
      #   Chef::Artifact.get_actual_version(node, "com.myartifact:my-artifact:1.0.1:tgz")  => "1.0.1"
      # 
      # @return [String] the version number that latest resolves to or the passed in value
      def get_actual_version(node, artifact_location)
        version = artifact_location.split(':')[2]
        if version.casecmp("latest") == 0
          require 'nexus_cli'
          require 'rexml/document'
          config = nexus_config_for(node)
          remote = NexusCli::RemoteFactory.create(config, config[:ssl_verify])
          REXML::Document.new(remote.get_artifact_info(artifact_location)).elements["//version"].text
        else
          version
        end
      end

      # Downloads a file to disk from the configured Nexus server.
      # 
      # @param  node [Chef::Node] the node
      # @param  source [String] a colon-separated Maven identified string that represents the artifact
      # @param  destination_dir [String] a path to download the artifact to
      #
      # @option options [Boolean] :ssl_verify
      #   a boolean to pass through to the NexusCli::RemoteFactory#create method indicated whether
      #   ssl methods should or should not be verified.
      # 
      # @return [Hash] writes a file to disk and returns a Hash with
      # information about that file. See NexusCli::ArtifactActions#pull_artifact.
      def retrieve_from_nexus(node, source, destination_dir, options = {})
        require 'nexus_cli'
        config = nexus_config_for(node)
        remote = NexusCli::RemoteFactory.create(config, options[:ssl_verify])
        remote.pull_artifact(source, destination_dir)
      end

      # Generates a URL that hits the Nexus redirect endpoint which will
      # result in an artifact being downloaded.
      #
      # @example
      #   Chef::Artifact.artifact_download_url_for(node, "com.myartifact:my-artifact:1.0.1:tgz")
      #     => "http://my-nexus:8081/nexus/service/local/artifact/maven/redirect?g=com.myartifact&a=my-artifact&v=1.0.1&e=tgz&r=my_repo"
      #
      # @param  node [Chef::Node]
      # @param  source [String] colon separated Nexus location
      # 
      # @return [String] a URL that can be used to retrieve an artifact
      def artifact_download_url_for(node, source)
        # TODO: Move this method into the nexus-cli
        config = nexus_config_for(node)
        group_id, artifact_id, version, extension = source.split(':')
        query_string = "g=#{group_id}&a=#{artifact_id}&v=#{version}&e=#{extension}&r=#{config['repository']}"
        uri_for_url = URI(config['url'])
        builder = uri_for_url.scheme =~ /https/ ? URI::HTTPS : URI::HTTP
        builder.build(host: uri_for_url.host, port: uri_for_url.port, path: '/nexus/service/local/artifact/maven/redirect', query: query_string).to_s
      end

      # Makes a call to Nexus and parses the returned XML to return
      # the Nexus Server's stored SHA1 checksum for the given artifact.
      #
      # @param  node [Chef::Node] the node
      # @param  artifact_location [String] a colon-separated Maven identifier that represents the artifact
      #
      # @return [String] the SHA1 entry for the artifact
      def get_artifact_sha(node, artifact_location)
        require 'nexus_cli'
        require 'rexml/document'
        config = nexus_config_for(node)
        remote = NexusCli::RemoteFactory.create(config, config[:ssl_verify])
        REXML::Document.new(remote.get_artifact_info(artifact_location)).elements["//sha1"].text
      end

      # Returns true when the artifact is believed to be from a
      # Nexus source.
      #
      # @param  location [String] the artifact_location
      # 
      # @return [Boolean] true when the location is a colon-separated value
      def from_nexus?(location)
        !from_http?(location) && location.split(":").length > 2
      end

      # Returns true when the artifact is believed to be from an
      # http source.
      # 
      # @param  location [String] the artifact_location
      # 
      # @return [Boolean] true when the location matches http or https.
      def from_http?(location)
        location =~ URI::regexp(['http', 'https'])
      end

      # Returns the currently deployed version of an artifact given that artifacts
      # installation directory by reading what directory the 'current' symlink
      # points to.
      # 
      # @param  deploy_to_dir [String] the directory where an artifact is installed
      # 
      # @example
      #   Chef::Artifact.get_current_deployed_version("/opt/my_deploy_dir") => "2.0.65"
      # 
      # @return [String] the currently deployed version of the given artifact
      def get_current_deployed_version(deploy_to_dir)

        current_dir = ::File.join(deploy_to_dir, "current")
        if ::File.exists?(current_dir)
          ::File.basename(readlink(current_dir))
        end
      end

      # Looks for the given data bag in the cache and if not found, will load a
      # data bag item named for the chef_environment, '_wildcard', or the old 
      # 'nexus' value.
      #
      # @param  node [Chef::Node] the node
      # @param  data_bag [String] the data bag to load
      # 
      # @return [Chef::Mash] the data bag item in Mash form
      def encrypted_data_bag_for(node, data_bag)
        @encrypted_data_bags = {} unless @encrypted_data_bags

        if encrypted_data_bags[data_bag]
          return get_from_data_bags_cache(data_bag)
        else
          data_bag_item = encrypted_data_bag_item(data_bag, node.chef_environment)
          data_bag_item ||= encrypted_data_bag_item(data_bag, WILDCARD_DATABAG_ITEM)
          data_bag_item ||= encrypted_data_bag_item(data_bag, "nexus")
          @encrypted_data_bags[data_bag] = data_bag_item
          return data_bag_item
        end
        raise EncryptedDataBagNotFound.new(data_bag)
      end

      # @return [Hash]
      def encrypted_data_bags
        @encrypted_data_bags
      end

      # Loads an entry from the encrypted_data_bags class variable.
      #
      # @param data_bag [String] the data bag to find
      # 
      # @return [type] [description]
      def get_from_data_bags_cache(data_bag)
        encrypted_data_bags[data_bag]
      end

      # Loads an EncryptedDataBagItem from the Chef server and
      # turns it into a Chef::Mash, giving it indifferent access. Returns
      # nil when a data bag item is not found.
      #
      # @param  data_bag [String]
      # @param  data_bag_item [String]
      # 
      # @raise [Chef::Artifact::DataBagEncryptionError] when the data bag cannot be decrypted
      #   or transformed into a Mash for some reason (Chef 10 vs Chef 11 data bag changes).
      # 
      # @return [Chef::Mash]
      def encrypted_data_bag_item(data_bag, data_bag_item)
        Mash.from_hash(Chef::EncryptedDataBagItem.load(data_bag, data_bag_item).to_hash)
      rescue Net::HTTPServerException => e
        nil
      rescue NoMethodError
        raise DataBagEncryptionError.new
      end
    end
  end
end

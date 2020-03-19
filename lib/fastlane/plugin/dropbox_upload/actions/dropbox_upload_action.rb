require 'fastlane/action'
require 'net/http'
require 'dropbox_api'
require_relative '../helper/dropbox_upload_helper'

module Fastlane
  module Actions
    class DropboxUploadAction < Action
      def self.run(params)
        write_mode = params[:write_mode]
        update_rev = params[:update_rev]
        access_token = params[:access_token]
        file_path = params[:file_path]
        dropbox_path = params[:dropbox_path]
        enable_clear = params[:enable_clear]

        UI.message ''
        UI.message("The dropbox_upload plugin is working!")
        UI.message "Starting upload of #{file_path} to Dropbox"
        UI.message ''

        if write_mode.nil?
            write_mode = 'add'
        end
        if enable_clear.nil?
            enable_clear = false
        end
        if write_mode.eql? 'update'
            if update_rev.nil?
                UI.user_error! 'You need to specify `update_rev` when using `update` write_mode.'
            else
                DropboxApi::Metadata::WriteMode.new({
                    '.tag' => write_mode,
                    'update' => update_rev
                    })
            end
        end
        if access_token.nil?
            UI.user_error! 'You need to specify `access_token`'
        end

        client = DropboxApi::Client.new(access_token)
        fileSize = File.size(file_path)
        remain_space = is_space_enough(client, fileSize)
        if remain_space >= 0
            UI.message 'space is enough'
        elsif enable_clear
            UI.message "space almost fill need more #{-remain_space}, delete the earliest file"
            delete_earliest_file(client, -remain_space)
        else
            UI.user_error! "Can't to upload file to Dropbox, space is full!"
        end

        output_file = nil
        chunk_size = 157_286_400 # 150M
        destination_path = destination_path(dropbox_path, file_path)
        if fileSize < chunk_size
            output_file = upload(client, file_path, destination_path, write_mode)
        else
            output_file = upload_chunked(client, chunk_size, file_path, destination_path, write_mode)
        end

        if output_file.name != File.basename(file_path)
            UI.user_error! 'Failed to upload file to Dropbox'
          else
            UI.success "File revision: '#{output_file.rev}'"
            UI.success "Successfully uploaded file to Dropbox at '#{destination_path}'"
         end


      end

      def self.upload(client, file_path, destination_path, write_mode)
        begin
            client.upload destination_path, File.read(file_path), mode: write_mode
            rescue DropboxApi::Errors::UploadWriteFailedError => e
            UI.user_error! "Failed to upload file to Dropbox. Error message returned by Dropbox API: \"#{e.message}\""
        end

      end

      def self.upload_chunked(client, chunk_size, file_path, destination_path, write_mode)
        parts = chunker file_path, './part', chunk_size
        UI.message ''
        UI.important "The archive is a big file so we're uploading it in 150MB chunks"
        UI.message ''

        begin
            UI.message "Uploading part #1 (#{File.size(parts[0])} bytes)..."
            cursor = client.upload_session_start File.read(parts[0])
            parts[1..parts.size].each_with_index do |part, index|
                UI.message "Uploading part ##{index + 2} (#{File.size(part)} bytes)..."
                client.upload_session_append_v2 cursor, File.read(part)
            end

            client.upload_session_finish cursor, DropboxApi::Metadata::CommitInfo.new('path' => destination_path,
                                                                                    'mode' => write_mode)
        rescue DropboxApi::Errors::UploadWriteFailedError => e
            UI.user_error! "Error uploading file to Dropbox: \"#{e.message}\""
        ensure
            parts.each { |part| File.delete(part) }
        end
      end

      def self.destination_path(dropbox_path, file_path)
        "#{dropbox_path}/#{File.basename(file_path)}"
      end

      def self.chunker(f_in, out_pref, chunksize)
        parts = []
        File.open(f_in, 'r') do |fh_in|
          until fh_in.eof?
            part = "#{out_pref}_#{format('%05d', (fh_in.pos / chunksize))}"
            File.open(part, 'w') do |fh_out|
              fh_out << fh_in.read(chunksize)
            end
            parts << part
          end
        end
        parts
      end

      def self.is_space_enough(client, fileSize)
        spaceUsage = client.get_space_usage
        used = spaceUsage.used.to_i
        allocated = spaceUsage.allocation.allocated
        unuse = allocated - used
        UI.important "Space allocated: #{allocated} used: #{used}  unuse: #{unuse} "
        if fileSize > allocated
            UI.user_error! 'Upload file size over allocated space'
        end
        return unuse - fileSize
      end

      def self.delete_earliest_file(client, space)
        UI.message ''
        UI.important "Need space #{space}"
        UI.message ''
        delete_space = 0
        files = get_all_files(client)
        files.each { |file|
            delete_space = delete_space + delete_file(client, file)
            if delete_space > space
                break
            end
          }
        UI.important "Delete space #{delete_space}"
      end

      def self.delete_file(client, file)
        path_display = file.path_display
        delete_result = client.delete path_display
        UI.message  "Delete file:#{file.path_display} size:#{file.size}"
        return delete_result.size
      end

      def self.get_all_files(client)
        files = list_folder(client)
        files.sort_by { |a|
            a.client_modified
        }
        return files
      end

      def self.list_folder(client, path = '')
        UI.important "List files in path #{path} "
        options = {}
        options[:recursive] = true
        options[:include_media_info] = false
        options[:include_deleted] = false
        folderResult = client.list_folder path, options
        files = get_tagfile(folderResult)
        if folderResult.has_more?
            more_files = list_folder_continue(client, folderResult.cursor)
            files.concat(more_files)
        end
        return files
      end

      def self.list_folder_continue(client, cursor)
        folderResult = client.list_folder_continue cursor
        files = get_tagfile(folderResult)
        if folderResult.has_more?
            more_files = list_folder_continue(client, folderResult.cursor)
            files.concat(more_files)
        end
        return files
      end

      def self.get_tagfile(result)
        files = []
        entries = result.entries
        entries[1..entries.size].each do |obj|
            if obj.class == DropboxApi::Metadata::File
                files.push(obj)
                UI.message  "File:#{obj.path_display} size:#{obj.size}"
            end
        end
        return files
      end

      def self.description
        "upload files to dropbox"
      end

      def self.authors
        ["jason"]
      end

      def self.return_value
        # If your method provides a return value, you can describe here what it does
      end

      def self.details
        # Optional:
        "use dropbox devlop access_token"
      end

      def self.available_options
        [
            FastlaneCore::ConfigItem.new(key: :file_path,
                                       env_name: 'DROPBOX_FILE_PATH',
                                       description: 'Path to the uploaded file',
                                       type: String,
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("No file path specified for upload to Dropbox, pass using `file_path: 'path_to_file'`") unless value && !value.empty?
                                         UI.user_error!("Couldn't find file at path '#{value}'") unless File.exist?(value)
                                       end),
            FastlaneCore::ConfigItem.new(key: :dropbox_path,
                                       env_name: 'DROPBOX_PATH',
                                       description: 'Path to the destination Dropbox folder',
                                       type: String,
                                       optional: true),
            FastlaneCore::ConfigItem.new(key: :write_mode,
                                       env_name: 'DROPBOX_WRITE_MODE',
                                       description: 'Determines uploaded file write mode. Supports `add`, `overwrite` and `update`',
                                       type: String,
                                       optional: true,
                                       verify_block: proc do |value|
                                         UI.command_output("write_mode '#{value}' not recognized. Defaulting to `add`.") unless value =~ /(add|overwrite|update)/
                                       end),
          FastlaneCore::ConfigItem.new(key: :update_rev,
                                       env_name: 'DROPBOX_UPDATE_REV',
                                       description: 'Revision of the file uploaded in `update` write_mode',
                                       type: String,
                                       optional: true,
                                       verify_block: proc do |value|
                                         UI.user_error!("Revision no. must be at least 9 hexadecimal characters ([0-9a-f]).") unless value =~ /[0-9a-f]{9,}/
                                       end),
          FastlaneCore::ConfigItem.new(key: :access_token,
                                       env_name: 'DROPBOX_ACCESS_TOKEN',
                                       description: 'access_token of your upload Dropbox',
                                       type: String,
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("access_token not specified for Dropbox app. Provide your app's access_token or create a new ") unless value && !value.empty?
                                       end),
        FastlaneCore::ConfigItem.new(key: :enable_clear,
                                     env_name: 'ENABLE_CLEAR',
                                     description: 'enable delete file when space is full',
                                     type: Boolean,
                                     optional: true,
                                     )
        ]
      end

      def self.example_code
        [
          'dropbox_upload(
            file_path: "./path/to/file.txt",
            dropbox_path: "/My Dropbox Folder/Text files",
            write_mode: "add/overwrite/update",
            update_rev: "a1c10ce0dd78",
            access_token: "your dropbox access_token"
          )'
        ]
      end

      def self.is_supported?(platform)
        # Adjust this if your plugin only works for a particular platform (iOS vs. Android, for example)
        # See: https://docs.fastlane.tools/advanced/#control-configuration-by-lane-and-by-platform
        #
        # [:ios, :mac, :android].include?(platform)
        true
      end
    end
  end
end

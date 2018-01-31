# frozen_string_literal: true

self.class.send(:include, Chef::Mixin::Securable::WindowsMacros)

resource_name :remote_file_s3

default_action :create

property :path, String, name_property: true, desired_state: false, callbacks: {
  'parent directory should exist' => lambda { |f|
    Dir.exist?(::File.dirname(f))
  }
}
property :remote_path, String, required: true, desired_state: false,
                               coerce: proc { |p| p.start_with?('/') ? p[1..-1] : p }
property :bucket, String, required: true, desired_state: false
property :aws_access_key_id, String, desired_state: false
property :aws_secret_access_key, String, sensitive: true, desired_state: false, identity: false
property :aws_session_token, String, sensitive: true, desired_state: false, identity: false
property :region, String, desired_state: false # default is handled in load_current_value
property :owner, [String, Integer], default: ENV['USER'], coerce: proc { |o| o.is_a?(String) && node['os'] != 'windows' ? Etc.getpwnam(o)&.uid : o }
property :group, [String, Integer], default: node['root_group'], coerce: proc { |g| g.is_a?(String) && node['os'] != 'windows' ? Etc.getgrnam(g).gid : g }
property :mode, [String, Integer], coerce: proc { |m| m.is_a?(String) ? m.to_i(8) : m }
property :inherits, [true, false]
property :sha256, String # property is used for state and not intended to be set during usage
property :etag, String # property is used for state and not intended to be set during usage
rights_attribute(:rights)
rights_attribute(:deny_rights)

action_class do
  def whyrun_supported?
    true
  end
end

# Load the AWS SDK gem, installing if needed
def deps(new_resource) # rubocop:disable Metrics/AbcSize
  begin
    require 'aws-sdk-s3'
  rescue LoadError
    node.run_context.include_recipe 'remote_file_s3::deps'
    require 'aws-sdk-s3'
  end

  creds = if new_resource.aws_access_key_id.nil? && node.key?('ec2')
            Aws::InstanceProfileCredentials.new
          else
            Aws::Credentials.new(
              new_resource.aws_access_key_id,
              new_resource.aws_secret_access_key,
              new_resource.aws_session_token
            )
          end

  Aws.config.update(credentials: creds)
end

def safe_stat(path)
  ::File::Stat.new(path)
rescue Errno::ENOENT
  nil
end

load_current_value do |new_resource|
  deps(new_resource)

  # Take defaults from existing file
  stat = safe_stat(new_resource.path)
  new_resource.owner = stat&.uid || ENV['USER'] if new_resource.owner.nil?
  new_resource.group = stat&.gid || node['root_group'] if new_resource.group.nil?
  new_resource.mode = stat&.mode & 32_767 || 0o0644 if new_resource.mode.nil?
  new_resource.sha256 = Digest::SHA256.file(new_resource.path).hexdigest unless stat.nil?

  current_value_does_not_exist! if stat.nil?

  # Load metadata from existing file
  owner stat.uid
  group stat.gid
  mode stat.mode & 32_767

  # Load the current values of last download from stored catalog
  catalog = Aws::S3Catalog.new
  sha256 catalog[new_resource.path]['sha256']
  etag catalog[new_resource.path]['etag']

  # Load the current etag from S3
  s3 = Aws::S3::Resource.new(region: new_resource.region)
  obj = s3.bucket(new_resource.bucket).object(new_resource.remote_path)
  new_resource.etag = obj.etag.tr('"', '')

  # Load region from ohai data
  new_resource.region = node['ec2']&.fetch('region', nil) || 'us-west-2'
end

action :create do
  deps(new_resource)

  # Ensure temp directory exists
  cache_path = ::File.join(::Chef::Config[:file_cache_path], 'remote_file_s3')
  Dir.mkdir(cache_path, 0o0700) unless Dir.exist?(cache_path)

  converge_if_changed :sha256, :etag do
    converge_by 'download file from s3' do
      # Prep the S3 object
      s3 = Aws::S3::Resource.new(region: new_resource.region)
      obj = s3.bucket(new_resource.bucket).object(new_resource.remote_path)

      # Download file to temp directory
      temp_file = Tempfile.new('s3file', cache_path, mode: 0o0700)
      temp_file.close
      file "set temp file #{temp_file.path} permissions" do
        path temp_file.path
        owner ENV['USER']
        group node['root_group']
        rights :full_control, ENV['USER']
        rights :full_control, 'Administrators'
        only_if { node['os'] == 'windows' }
      end.run_action(:create)
      obj.download_file(temp_file.path)

      # Update catalog for future runs
      catalog = Aws::S3Catalog.new
      etag = obj.etag.tr('"', '')
      catalog[new_resource.path] = { etag: etag, sha256: Digest::SHA256.file(temp_file.path).hexdigest }
      catalog.save

      # Set file metadata and atomically move
      stat = safe_stat(new_resource.path)
      file temp_file.path do
        if node['os'] == 'windows'
          instance_variable_set(:@rights, new_resource.rights)
          instance_variable_set(:@deny_rights, new_resource.deny_rights)
          inherits new_resource.inherits unless new_resource.inherits.nil?
        else
          owner stat&.uid || new_resource.owner unless node['os'] == 'windows'
          group stat&.gid || new_resource.group unless node['os'] == 'windows'
          mode stat&.mode & 32_767 || new_resource.mode unless node['os'] == 'windows'
        end
      end.run_action(:create)
      FileUtils.mv(temp_file.path, new_resource.path)
    end
  end

  # Still ensure permissions even if content hasn't changed
  file new_resource.path do
    owner new_resource.owner unless new_resource.owner.nil?
    group new_resource.group unless new_resource.group.nil?
    mode new_resource.mode unless new_resource.mode.nil?
    if node['os'] == 'windows'
      instance_variable_set(:@rights, new_resource.rights)
      instance_variable_set(:@deny_rights, new_resource.deny_rights)
      inherits new_resource.inherits unless new_resource.inherits.nil?
    end
  end
end

action :create_if_missing do
  run_action(:create) unless ::File.exist?(new_resource.path)
end

action :delete do
  if ::File.exist?(new_resource.path)
    ::File.unlink(new_resource.path)

    catalog = Aws::S3Catalog.new
    catalog.remove_file(new_resource.path)
    catalog.save
  end
end

class Job < ApplicationRecord
  validates_presence_of :url_1, :url_2
  validates_uniqueness_of :id

  def check_status
    return if sidekiq_id.blank?
    return if finished?
    update(status: Sidekiq::Status.status(sidekiq_id))
  end

  def finished?
    ['complete', 'error'].include?(status)
  end

  def generate_diff_async
    sidekiq_id = GenerateDiffWorker.perform_async(id)
    update(sidekiq_id: sidekiq_id)
  end

  def generate_diff
    begin
      Dir.mktmpdir do |dir|
        sha256_1 = download_file(url_1, dir)
        sha256_2 = download_file(url_2, dir)
        results = diff(dir)
        update!(results: results, status: 'complete', sha256_1: sha256_1, sha256_2: sha256_2)
      end
    rescue => e
      update(results: {error: e.inspect}, status: 'error')
    end
  end

  def diff(dir)
    path_1 = File.join([dir, File.basename(url_1)])
    path_2 = File.join([dir, File.basename(url_2)])

    str = `diffoscope #{path_1} #{path_2} --json -`
    json = JSON.parse(str)

    return {diff: json}
  end

  def download_file(url, dir)
    path = File.join([dir, File.basename(url)])
    downloaded_file = File.open(path, "wb")

    request = Typhoeus::Request.new(url, followlocation: true)
    request.on_headers do |response|
      return nil if response.code != 200
    end
    request.on_body { |chunk| downloaded_file.write(chunk) }
    request.on_complete { downloaded_file.close }
    request.run

    return Digest::SHA256.hexdigest File.read(path)
  end
end
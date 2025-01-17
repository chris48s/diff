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

  def to_s
    id
  end

  def details
    return nil if results["diff"].nil?
    results["diff"]["details"].find{|d| d['details'].present?}['details'][1..-1].map do |detail|
      lines = detail['unified_diff'].present? ? detail['unified_diff'] : detail['details'].first['unified_diff']
"
diff --git a/#{detail['source1']} b/#{detail['source2']}
#{'deleted file mode 000000' if detail['source2'] == '/dev/null'}
#{'new file mode 100644' if detail['source1'] == '/dev/null'}
index 0000001..0ddf2ba
--- #{detail['source1']}
+++ #{detail['source2']}
#{lines}
"
    end.join("\n")
  end

  def generate_diff
    begin
      Dir.mktmpdir do |dir|
        sha256_1 = download_file(url_1, dir)
        sha256_2 = download_file(url_2, dir)
        if sha256_1.present? && sha256_2.present?
          results = diff(dir)
          update!(results: results, status: 'complete', sha256_1: sha256_1, sha256_2: sha256_2)
        else
          errors = []
          errors << "Error downloading url_1: #{url_1}" if sha256_1.blank?
          errors << "Error downloading url_2: #{url_2}" if sha256_2.blank?
          results = {errors: errors}
          update!(results: results, status: 'error')
        end
      end
    rescue => e
      update(results: {error: e.inspect}, status: 'error')
    end
  end

  def basename_1
    File.basename(url_1)
  end

  def basename_2
    File.basename(url_2)
  end

  def diff(dir)
    path_1 = File.join([dir, basename_1])
    path_2 = File.join([dir, basename_2])

    str = `diffoscope #{path_1} #{path_2} --new-file --json -`
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

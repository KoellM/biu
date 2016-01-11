#!/usr/bin/env ruby
# TODO:
# 上传队列

require 'rubygems'
require 'digest/md5'
require 'net/http'
require 'net/https'
require 'uri'
require 'optparse'
require 'thread'
require 'streamio-ffmpeg'
require 'colorize'
require 'rest-client'
require 'json'

def check_bit?(codec, bitrate)
  if codec == 'mp3'
    return true if bitrate.to_s >= '320'
  elsif codec == 'aac'
    return true if bitrate.to_s >= '256'
  else
    return true if codec=='flac' || codec=='ape' || codec=='wav' || codec=='tta' || codec=='tak' || codec=='alac'
  end
end

def get_token(info)
  url = URI.parse('https://api.biu.moe/Api/createSong')
  res = Net::HTTP.new(url.host, url.port)
  res.use_ssl = true
  res.verify_mode = OpenSSL::SSL::VERIFY_NONE
  req = Net::HTTP::Post.new(url.path)
  if info[:force]
    req.set_form_data({'uid' => $uid, 'filemd5' => info[:md5], 'title' => info[:title], 'singer' => info[:artist], 'album' => info[:album], 'remark' => $remark, 'sign' => info[:sign], 'force' => 1}, '&')
  else
    req.set_form_data({'uid' => $uid, 'filemd5' => info[:md5], 'title' => info[:title], 'singer' => info[:artist], 'album' => info[:album], 'remark' => $remark, 'sign' => info[:sign]}, '&')
  end
  res.request(req)
end

def upload_qiniu(info, token)
  RestClient.post('http://upload.qiniu.com/', :file => File.new(info[:file], 'rb'), :key => info[:md5], "x:md5" => info[:md5], :token => token)
end

def get_id3(path)
  command = <<-end_command
      ffprobe -v quiet -print_format json -show_format "#{path}" > ./info.json
  end_command
  command.gsub!(/\s+/, " ")
  system(command)
end

# 全局变量
$uid = '152'
$remark = ''
$key = 'ZYeNPAoLOJlSoKIQrwIlmcedYbdxakrQ'

# 新建队列
$queue = Queue.new
$upload_queue = Queue.new

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: Biu.rb [options]"

  opts.on("-c", "--codec CODEC", "音乐格式 ") do |codec|
    options[:codec] = codec
  end

  opts.on("-f", "--file FILE", "文件路径 ") do |file|
    options[:file] = file
  end

  opts.on("-t", "--threads INT", "线程数[注意:开启线程后不能使用强制上传] ") do |threads|
    options[:threads] = threads
  end
end.parse!

threads = []

# 输入歌曲路径
path = options[:file].to_s
path = '.' if path == ''

n = options[:codec].to_s
n = 'flac' if n == ''

# 遍历目录文件
Dir.glob(path + '/*.' + n) do |file|
  begin
    movie = FFMPEG::Movie.new(file)
    md5 = Digest::MD5.file(file).to_s
    get_id3(file)
    tag = open(path + '/info.json') do |get|
      JSON.load(get)
    end
    tag = tag['format']['tags']
    if tag['title'].nil?
      title = tag['TITLE']
      artist = tag['ARTIST']
      album = tag['ALBUM']
    else
      title = tag['title']
      artist = tag['artist']
      album = tag['album']
    end
    puts "曲名:#{title}\n格式:#{movie.audio_codec}音质:#{movie.bitrate}\nMD5:#{md5}\nID3:\n#{title}\n#{artist}\n#{album}\n".yellow

    $queue.push(title: title, artist: artist, album: album, file: file, md5: md5, bitrate: movie.bitrate, codec: movie.audio_codec)
  rescue
    puts "获取信息失败."
  end
end

puts '没有遍历到任何文件'.yellow if $queue.empty?

# 检测音质等(大坑)
until $queue.empty?
  file = $queue.pop(true) rescue nil

  if file[:title] == '' || file[:title] == nil
    print "检测到 #{file[:file]} ID3的标题为空,请输入歌名: "
    STDOUT.flush
    file[:title] = gets.to_s.chomp
  end

  sign = Digest::MD5.hexdigest($uid + file[:md5] + file[:title] + file[:artist] + file[:album] + $remark + $key)
  $upload_queue.push(title: file[:title], artist: file[:artist], album: file[:album], file: file[:file], md5: file[:md5], sign: sign) if check_bit?(file[:codec], file[:bitrate])
end

# 上传队列
threadNums = options[:threads].to_s
threadNums = 1 if threadNums == ''
threadNums.times do
  threads<<Thread.new do
    until $upload_queue.empty?
      info = $upload_queue.pop(true) rescue nil
      begin
        resp = get_token(info)
      rescue SocketError
        puts "获取失败,请检查网络."
      end

      case resp
        when Net::HTTPSuccess
          json = JSON.parse(resp.body)
          if json['success'] == true
            puts "获取令牌成功,开始上传:#{info[:title]}".green
            token = json['token']
            begin
              upload_qiniu(info, token)
              puts '上传成功'.green
            rescue
              puts '上传失败'.yellow
            end
          else
            puts "\n歌曲: #{info[:title]} 获取令牌失败,错误代码: #{json['error_code']}.".yellow
            case json['error_code'].to_i
              when 1
                puts "Sign 签名校检失败."
              when 2
                puts "系统检测疑似撞车."
                result = json['result']
                puts "\n系统检测疑似到稿件撞车,请详细核对确认是否撞车.\n".red
                puts "本地歌曲信息: 曲名: #{info[:title]} | 歌手: #{info[:artist]} | 专辑: #{info[:album]}"
                result.each do |r|
                  case r['level'].to_i
                    when 1
                      r['level'] = '无损'
                    when 2
                      r['level'] = '高音质 AAC'
                    when 3
                      r['level'] = '高音质 MP3'
                    when 4
                      r['level'] = '渣音质 MP3'
                  end
                  puts "撞车可能性评分#{r['score']} | 歌曲ID: #{r['sid']} | 曲名: #{r['title']} | 歌手: #{r['singer']} | 专辑: #{r['album']} | 音质: #{r['level']} \n "
                end
                print '确认没有撞车强行上传请按1,我要放弃上传请按2: '
                STDOUT.flush
                up = gets.to_s.chomp
                if up.to_i == 1
                  $upload_queue.push(title: info[:title], artist: info[:artist], album: info[:album], file: info[:file], md5: info[:md5], sign: info[:sign], force: 1)
                  puts "已加入上传队列".green
                end
              when 3
                puts "未通过审核的歌曲超过 100 首，请先进入网站『我上传的音乐』删除一部分未通过的文件."
              when 4
                puts "参数不齐，至少歌曲名不能为空."
              when 5
                puts "服务器已存在该文件（撞 MD5）."
            end
          end
        else
          puts "获取失败,请检查网络状态."
      end
    end
  end
end
# 注: 线程好像并没有什么用.
threads.each { |t| t.join }
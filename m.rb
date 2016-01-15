#!/usr/bin/env ruby
# TODO:
# Windows 适配

require 'rubygems'
require 'digest/md5'
require 'net/http'
require 'net/https'
require 'uri'
require 'optparse'
require 'thread'
require 'bundler'
require 'colorize' unless RUBY_PLATFORM=~ /java/
require 'rest-client'
require 'json'
require 'curb' unless RUBY_PLATFORM=~ /win32|mswin|mingw|java/

def check_bit?(codec, bitrate)
  bitrate = bitrate.to_i
  if codec == 'mp3' and bitrate / 1000 > 300
    return true
  elsif codec == 'aac' and bitrate / 1000 > 210
    return true
  elsif ['flac', 'ape', 'wav', 'tta', 'tak', 'alac'].include?(codec)
    return true
  end
end

def get_token_or_upload_qiniu(info, token = nil)
  begin
    if info[:force]
      RestClient.post('https://api.biu.moe/Api/createSong', 'uid' => $uid, 'filemd5' => info[:md5], 'title' => info[:title], 'singer' => info[:artist], 'album' => info[:album], 'remark' => $remark, 'sign' => info[:sign], 'force' => info[:fource])
    elsif token
      begin
        curl = Curl::Easy.new('http://upload.qiniu.com/')
        curl.multipart_form_post = true
        curl.on_progress do |_, _, upload_size, uploaded|
            uploaded = uploaded / 1000000
            upload_size = upload_size / 1000000
            print "\r已上传: #{uploaded.to_s.slice(0..3)}M / 共: #{upload_size.to_s.slice(0..3)}M"
            true
        end
        curl.on_success { |easy| puts "\nsuccess" }
        puts "正在上传: #{info[:title]}"
        curl.http_post(Curl::PostField.file('file', info[:file]),
                        Curl::PostField.content('key', info[:md5]),
                        Curl::PostField.content('x:md5', info[:md5]),
                        Curl::PostField.content('token', token))
      rescue
        RestClient.post('http://upload.qiniu.com/', :file => File.new(info[:file], 'rb'), :key => info[:md5], "x:md5" => info[:md5], :token => token)
      end          
    else
      RestClient.post('https://api.biu.moe/Api/createSong', 'uid' => $uid, 'filemd5' => info[:md5], 'title' => info[:title], 'singer' => info[:artist], 'album' => info[:album], 'remark' => $remark, 'sign' => info[:sign])
    end
  rescue
    puts "Error"
  end
end


def get_id3(path)
  command = <<-end_command
      ffprobe -v quiet -print_format json -show_format "#{path}" > ./info.json
  end_command
  command.gsub!(/\s+/, " ")
  cmd = system(command)
  if cmd == false
    puts "系统可能没有安装 FFMPEG, 正在尝试使用 info.exe 获取."
    command = <<-end_command
        info.exe -v quiet -print_format json -show_format "#{path}" > ./info.json
    end_command
    command.gsub!(/\s+/, " ")
    cmd = system(command)
  end
  return cmd
end

# 全局变量
$uid = '152'
$remark = ''
$key = ''

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
    md5 = Digest::MD5.file(file).to_s
    get_id3(file)
    info = open('./info.json') do |get|
      JSON.load(get)
    end
    tag = info['format']['tags']
    format_name = info['format']['format_name']
    bit_rate = info['format']['bit_rate']
    if tag['title'].nil?
      title = tag['TITLE']
      artist = tag['ARTIST']
      album = tag['ALBUM']
    else
      title = tag['title']
      artist = tag['artist']
      album = tag['album']
    end
    puts "曲名:#{title}\n格式:#{format_name} 音质:#{bit_rate}\nMD5:#{md5}\nID3:\n#{title}\n#{artist}\n#{album}\n".yellow

    $queue.push(title: title, artist: artist, album: album, file: file, md5: md5, bitrate: bit_rate, codec: format_name)
  rescue
    puts '获取信息失败.'
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
        resp = get_token_or_upload_qiniu(info)
      rescue SocketError
        puts "获取失败,请检查网络."
      end
      if resp.code == 200
        json = JSON.parse(resp.body)
        if json['success'] == true
          puts "\n获取令牌成功,开始上传:#{info[:title]}".green
          token = json['token']
          begin
            res = get_token_or_upload_qiniu(info, token)
            if res == true || res.code == 200
              puts "\n上传成功".green
            else
              puts '上传失败'
            end
          rescue
            puts '上传失败'
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
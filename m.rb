# App Version 0.1
### 渣渣音乐上传工具 ###
#
# TODO:
# 上传队列
#
######## 以上 ########
require 'streamio-ffmpeg' # ffmpeg
require 'digest/md5' # md5
require 'easytag' # ID3
require 'colorize'
require 'rest-client'

puts 'BiuBiuBiu'.light_blue

# 新建队列
$queue = Queue.new
$upload_queue = Queue.new #上传队列已坑:(

# 输入歌曲路径
puts '请输入歌曲的目录位置,如果歌曲在当前目录请直接按回车(｀･ω･´).'.yellow
path = gets.chomp
puts "目录: #{path} 已设定.开始遍历目录文件.".green

# 遍历目录文件
Dir.glob(path + '/*.flac') do |file|
  # 将歌曲信息存入队列
  $queue.push(file)
end

# 读取队列
until $queue.empty?
  file = $queue.pop(true) rescue nil
  movie = FFMPEG::Movie.new(file) # FFMPEG
  md5 = Digest::MD5.file(file).to_s # MD5
  tag = EasyTag.open(file) # ID3
  puts "曲名:#{tag.title}  \n格式:#{movie.audio_codec} 音质:#{movie.bitrate}\nMD5:#{md5}\nID3:\n#{tag.title}\n#{tag.artist}\n#{tag.album}\n".yellow
  # 将信息存入上传
  $upload_queue.push(title: tag.title, artist: tag.artist, album: tag.album, file: file, md5: md5)
end

# puts ''.green


#上传队列
until $upload_queue.empty?
  info = $upload_queue.pop(true) rescue nil
  file = info[:file]
  md5 = info[:md5]
  RestClient.post('http://localhost:3000/upload',
                  name_of_file_param: File.new(file))
end
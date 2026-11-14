// VCSC standalone Stella RawStream v1 reader. No Stella source dependencies.
#include <png.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
static void fail(const std::string& s) { throw std::runtime_error(s); }
static uint32_t number(const std::string& s) {
  if(s.empty() || s.find_first_not_of("0123456789") != std::string::npos)
    fail("invalid unsigned frame/option number: " + s);
  uint64_t n = 0;
  for(char c : s) {
    n = n * 10 + unsigned(c - '0');
    if(n > UINT32_MAX) fail("number exceeds uint32: " + s);
  }
  return uint32_t(n);
}
struct Selection {
  std::vector<std::pair<uint32_t,uint32_t>> ranges;
  void parse(const std::string& text) {
    size_t start = 0;
    do {
      size_t end = text.find(',', start);
      std::string item = text.substr(start, end == std::string::npos ? end : end-start);
      size_t dash = item.find('-');
      uint32_t a = number(item.substr(0,dash));
      uint32_t b = dash == std::string::npos ? a : number(item.substr(dash+1));
      if(a > b) fail("descending frame range: " + item);
      ranges.emplace_back(a,b);
      if(end == std::string::npos) break;
      start = end+1;
    } while(true);
    std::sort(ranges.begin(),ranges.end());
    std::vector<std::pair<uint32_t,uint32_t>> merged;
    for(auto r : ranges) {
      if(!merged.empty() && uint64_t(r.first) <= uint64_t(merged.back().second)+1)
        merged.back().second = std::max(merged.back().second,r.second);
      else merged.push_back(r);
    }
    ranges = std::move(merged);
  }
  bool contains(uint32_t n) const {
    for(auto r : ranges) if(n >= r.first && n <= r.second) return true;
    return false;
  }
  uint64_t count() const {
    uint64_t n = 0;
    for(auto r : ranges) n += uint64_t(r.second)-r.first+1;
    return n;
  }
};
struct Options {
  std::string input, directory, prefix = "frame_";
  Selection selection;
  bool all=false, list=false, follow=false, finish=false;
  uint32_t timeout=60;
  uint64_t maxBytes=std::numeric_limits<uint64_t>::max();
};
static void help() {
  std::cout << "Usage: rawstream2png --input FILE [--frames '1,5-10,12' | --all] --output-dir DIR\n"
    "       rawstream2png --input FILE --list\n"
    "Options: --prefix TEXT (default frame_), --list (frame/ROM/timing metadata), --help\n"
    "Native RGB PNGs use the current recorded palette; numbers are FRAM identities.\n"
    "Ranges are inclusive decimal uint32 values (including frame 0), merged if overlapping.\n"
    "Existing files or repeated selected identities are errors, never overwritten.\n"
    "Ordinary input must end with END; unknown chunks and v1 extension fields are skipped.\n"
    "Live capture: --follow --finish-selected --timeout SECONDS --max-bytes BYTES\n"
    "Wait for partial chunks; finish successfully once every selected frame is complete,\n"
    "without requiring END or accepting any partial selected frame. Keep the producer bounded.\n";
}
static Options options(int argc, char** argv) {
  Options o;
  bool frames=false;
  for(int i=1;i<argc;++i) {
    std::string arg=argv[i];
    auto value=[&]() -> std::string {
      if(++i>=argc) fail("missing value for " + arg);
      return argv[i];
    };
    if(arg=="--help") { help(); std::exit(0); }
    else if(arg=="--input") o.input=value();
    else if(arg=="--output-dir") o.directory=value();
    else if(arg=="--prefix") o.prefix=value();
    else if(arg=="--frames") {
      if(frames) fail("--frames supplied twice");
      frames=true; o.selection.parse(value());
    }
    else if(arg=="--all") o.all=true;
    else if(arg=="--list") o.list=true;
    else if(arg=="--follow") o.follow=true;
    else if(arg=="--finish-selected") o.finish=true;
    else if(arg=="--timeout") o.timeout=number(value());
    else if(arg=="--max-bytes") {
      std::string text=value();
      if(text.empty() || text.find_first_not_of("0123456789")!=std::string::npos)
        fail("invalid byte limit: " + text);
      o.maxBytes=0;
      for(char c:text) {
        unsigned digit=unsigned(c-'0');
        if(o.maxBytes>(UINT64_MAX-digit)/10) fail("byte limit exceeds uint64");
        o.maxBytes=o.maxBytes*10+digit;
      }
    }
    else fail("unknown option: " + arg);
  }
  if(o.input.empty()) fail("--input is required");
  if(frames && o.all) fail("--frames and --all are mutually exclusive");
  if(!frames && !o.all && !o.list) fail("specify --frames, --all or --list");
  if((frames||o.all) && o.directory.empty()) fail("--output-dir is required for PNG export");
  if(o.prefix.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string::npos)
    fail("--prefix must contain only letters, digits, underscore, dot or hyphen");
  if(o.finish && (!o.follow || !frames)) fail("--finish-selected requires --follow and --frames");
  if(!o.timeout || !o.maxBytes) fail("timeout and byte limit must be positive");
  return o;
}

// All file reads (including unknown chunks) are bounded and incremental. Live
// readers never treat EOF in the middle of a chunk as a completed record.
class Input {
  std::ifstream file;
  const Options& o;
  std::chrono::steady_clock::time_point deadline;
  uint64_t offset=0;
public:
  explicit Input(const Options& options): o(options),
    deadline(std::chrono::steady_clock::now()+std::chrono::seconds(o.timeout)) {
    do {
      if(fs::exists(o.input) && !fs::is_regular_file(o.input)) fail("input must be a regular file");
      file.open(o.input,std::ios::binary);
      if(file) return;
      file.clear();
      if(!o.follow) fail("cannot open input: " + o.input);
      wait();
    } while(o.follow);
    fail("cannot open input: " + o.input);
  }
  void wait() {
    if(!o.follow) fail("missing END or truncated stream: " + o.input);
    if(std::chrono::steady_clock::now()>=deadline) fail("timeout waiting for raw stream at byte " + std::to_string(offset));
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  void read(unsigned char* dest, size_t n) {
    if(o.follow && std::chrono::steady_clock::now()>=deadline) fail("raw-stream overall timeout");
    if(n>o.maxBytes-offset) fail("raw-stream byte limit exceeded");
    while(n) {
      file.read(reinterpret_cast<char*>(dest),std::streamsize(n));
      size_t got=size_t(file.gcount());
      offset+=got; dest+=got; n-=got;
      if(file.bad()) fail("input I/O error");
      if(n) { file.clear(); wait(); }
    }
  }
  Bytes read(size_t n) { Bytes b(n); read(b.data(),n); return b; }
  void skip(uint32_t n) {
    std::array<unsigned char,8192> b{};
    while(n) { auto k=std::min<size_t>(n,b.size()); read(b.data(),k); n-=uint32_t(k); }
  }
  void end() {
    // END is definitive, even when following. Trailing bytes are invalid.
    if(file.peek()!=std::char_traits<char>::eof()) fail("data after END");
  }
};
class Payload {
  const Bytes& b;
  size_t at=0;
public:
  explicit Payload(const Bytes& bytes): b(bytes) {}
  uint64_t integer(size_t n) {
    if(n>b.size()-at) fail("short chunk payload");
    uint64_t v=0;
    for(size_t i=0;i<n;++i) v |= uint64_t(b[at++])<<(8*i);
    return v;
  }
  std::string text() {
    size_t n=size_t(integer(2));
    if(n>b.size()-at) fail("short HEAD string");
    std::string result(b.begin()+at,b.begin()+at+n); at+=n; return result;
  }
};
struct Header {
  uint16_t version=0,width=0;
  unsigned tv=0;
  uint32_t rate=0,cpuRate=0;
  std::array<int16_t,31> mono{};
  std::array<int16_t,16> stereo{};
  std::string rom,md5;
  void read(const Bytes& b) {
    Payload p(b);
    version=uint16_t(p.integer(2));
    if(version!=1) fail("unsupported RawStream version: " + std::to_string(version));
    tv=unsigned(p.integer(1));
    if(tv>2) fail("invalid TV type");
    p.integer(1); rate=uint32_t(p.integer(4)); cpuRate=uint32_t(p.integer(4));
    width=uint16_t(p.integer(2)); p.integer(2);
    if(width!=160) fail("invalid v1 HEAD width");
    for(auto& v:mono) v=int16_t(p.integer(2));
    for(auto& v:stereo) v=int16_t(p.integer(2));
    rom=p.text(); md5=p.text();
  }
};
struct Frame {
  uint64_t cycles;
  uint32_t number;
  uint16_t lines,first,width,height;
  explicit Frame(const Bytes& b) {
    Payload p(b);
    cycles=p.integer(8); number=uint32_t(p.integer(4));
    lines=uint16_t(p.integer(2)); first=uint16_t(p.integer(2));
    width=uint16_t(p.integer(2)); height=uint16_t(p.integer(2));
    if(width!=160 || height==0 || height>4096) fail("invalid FRAM dimensions");
    if(b.size()<20+size_t(width)*height) fail("short FRAM pixel payload");
  }
};
static void png(const fs::path& path, const Frame& frame, const Bytes& pixels,
                const std::array<unsigned char,768>& palette) {
  const fs::path temporary=path.string()+".partial";
  if(fs::exists(path)) fail("PNG already exists (never overwrite): " + path.string());
  int fd=::open(temporary.c_str(),O_WRONLY|O_CREAT|O_EXCL,0666);
  if(fd<0) fail("cannot create PNG (never overwrite): " + path.string()+": "+std::strerror(errno));
  FILE* out=fdopen(fd,"wb");
  if(!out) { close(fd); fs::remove(temporary); fail("fdopen PNG failed"); }
  png_image image{};
  image.version=PNG_IMAGE_VERSION; image.width=frame.width;
  image.height=frame.height; image.format=PNG_FORMAT_RGB_COLORMAP;
  image.colormap_entries=256;
  bool ok=png_image_write_to_stdio(&image,out,0,pixels.data()+20,0,palette.data())!=0;
  std::string error=image.message;
  if(std::fclose(out)!=0) ok=false;
  png_image_free(&image);
  if(!ok) { fs::remove(temporary); fail("PNG write failed: " + error); }
  if(::link(temporary.c_str(),path.c_str())!=0) {
    fs::remove(temporary); fail("cannot publish PNG (never overwrite): " + path.string());
  }
  fs::remove(temporary);
}
static void convert(const Options& o) {
  Input input(o);
  Header header;
  std::array<unsigned char,768> palette{};
  std::array<unsigned char,128> ram{};
  bool haveHeader=false,havePalette=false,haveRam=false;
  uint64_t audioSamples=0;
  std::set<uint32_t> exported;
  if(!o.directory.empty()) fs::create_directories(o.directory);
  while(true) {
    Bytes raw=input.read(8); Payload chunk(raw);
    std::string tag(raw.begin(),raw.begin()+4);
    chunk.integer(4); uint32_t length=uint32_t(chunk.integer(4));
    if(tag=="END ") {
      if(length) fail("END payload must be empty");
      input.end(); break;
    }
    if(tag=="AUDI") { input.skip(length); audioSamples+=length; continue; }
    if(tag!="HEAD" && tag!="PALT" && tag!="FRAM" && tag!="RAM " && tag!="JUMP") {
      input.skip(length); continue;
    }
    // Bound known records before allocation. Unknown extensions are skipped.
    if(length>1024*1024) fail("oversized " + tag + " chunk");
    Bytes b=input.read(length);
    if(tag=="HEAD") {
      header.read(b); haveHeader=true; havePalette=false; haveRam=false;
      if(o.list) std::cout << "HEAD\tversion="<<header.version<<"\ttv="<<header.tv
        <<"\taudio_rate="<<header.rate<<"\tcpu_rate="<<header.cpuRate
        <<"\trom="<<std::quoted(header.rom)<<"\tmd5="<<std::quoted(header.md5)<<'\n';
    } else if(tag=="PALT") {
      if(!haveHeader || b.size()<palette.size()) fail("PALT without HEAD or short palette");
      std::copy_n(b.begin(),palette.size(),palette.begin()); havePalette=true;
    } else if(tag=="RAM ") {
      if(!haveHeader || b.size()<ram.size()) fail("short RAM or RAM without HEAD");
      std::copy_n(b.begin(),ram.size(),ram.begin()); haveRam=true;
    } else if(tag=="JUMP") {
      if(b.empty()) fail("short JUMP");
      if(o.list) std::cout<<"JUMP\treason="<<unsigned(b[0])<<'\n';
      audioSamples=0; haveRam=false;
    } else {
      if(!haveHeader || !havePalette) fail("FRAM without current HEAD/PALT");
      Frame frame(b);
      if(o.list) {
        std::cout<<"FRAM\tframe="<<frame.number<<"\tcycles="<<frame.cycles
          <<"\tscanlines="<<frame.lines<<"\tfirst="<<frame.first<<"\twidth="<<frame.width
          <<"\theight="<<frame.height<<"\ttv="<<header.tv<<"\taudio_samples="<<audioSamples;
        if(haveRam) {
          std::cout<<"\tram=";
          for(auto byte:ram) std::cout<<std::hex<<std::setfill('0')<<std::setw(2)<<unsigned(byte);
          std::cout<<std::dec;
        }
        std::cout<<'\n';
      }
      if(o.all || o.selection.contains(frame.number)) {
        if(!exported.insert(frame.number).second) fail("duplicate selected frame identity: " + std::to_string(frame.number));
        std::ostringstream name;
        name<<o.prefix<<std::setfill('0')<<std::setw(8)<<frame.number<<".png";
        png(fs::path(o.directory)/name.str(),frame,b,palette);
      }
      audioSamples=0; haveRam=false;
      if(o.finish && exported.size()==o.selection.count()) return;
    }
  }
  if(!haveHeader) fail("stream has no HEAD");
  if(!o.selection.ranges.empty() && exported.size()!=o.selection.count()) {
    for(auto r:o.selection.ranges) {
      uint64_t n=r.first;
      while(n<=r.second && exported.count(uint32_t(n))) ++n;
      if(n<=r.second) fail("missing requested frame: " + std::to_string(n));
    }
  }
}
int main(int argc,char** argv) {
  try { convert(options(argc,argv)); return 0; }
  catch(const std::exception& e) { std::cerr<<"rawstream2png: "<<e.what()<<'\n'; return 1; }
}

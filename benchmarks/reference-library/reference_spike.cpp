#define BOOST_MP_STANDALONE
#include <boost/multiprecision/cpp_bin_float.hpp>
#include <chrono>
#include <iostream>
#include <vector>
#include <cmath>
struct XF { float hi,lo; int exponent,pad; };
struct XC { XF x,y; };
template<class F> XF pack(const F& x) {
 if(x==0) return {0,0,0,0};
 int exponent;
 F m=frexp(x,&exponent)*2; --exponent;
 double d=m.template convert_to<double>();
 float hi=float(d);return {hi,float(d-double(hi)),exponent,0};
}
template<unsigned Bits> void run(const char* real,const char* imag) {
 using F=boost::multiprecision::number<boost::multiprecision::cpp_bin_float<Bits,boost::multiprecision::digit_base_2>>;
 F cr(real),ci(imag);double checksum=0;std::vector<size_t> lengths;
 std::cout<<"{\"library\":\"Boost-1.90-saved-reference\",\"bits\":"<<Bits<<",\"seconds\":[";
 for(int r=0;r<5;r++) {
  auto start=std::chrono::steady_clock::now();
  std::vector<XC> values;values.reserve(4096);F x=0,y=0;
  for(int n=0;n<=60000;n++) {
   values.push_back({pack(x),pack(y)});
   F xx=x*x,yy=y*y;
   if(xx+yy>65536 || n==60000) break;
   y=2*x*y+ci;x=xx-yy+cr;
  }
  double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
  if(r)std::cout<<",";std::cout<<elapsed;
  lengths.push_back(values.size());for(auto z:values)checksum+=z.x.hi;
 }
 std::cout<<"],\"lengths\":[";
 for(size_t i=0;i<lengths.size();i++){if(i)std::cout<<",";std::cout<<lengths[i];}
 std::cout<<"],\"checksum\":"<<checksum<<"}\n";
}
int main(int argc,char** argv){if(argc!=3)return 2;run<461>(argv[1],argv[2]);run<512>(argv[1],argv[2]);}

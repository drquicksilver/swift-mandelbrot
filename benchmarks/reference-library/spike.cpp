// The arithmetic half of the reference-library spike in Boost's cpp_bin_float,
// the counterpart of spike.swift; README.md explains, reproduce.py builds it.

#define BOOST_MP_STANDALONE
#include <boost/multiprecision/cpp_bin_float.hpp>
#include <chrono>
#include <iostream>
#include <cmath>
template<unsigned Bits> void run(int digits) {
 using F=boost::multiprecision::number<boost::multiprecision::cpp_bin_float<Bits,boost::multiprecision::digit_base_2>>;
 F cr=F("-0.743643887037151"),ci=F("0.13182590390533"); double checksum=0;
 std::cout<<"{\"library\":\"Boost-1.90-cpp_bin_float\",\"digits\":"<<digits<<",\"bits\":"<<Bits<<",\"seconds\":[";
 for(int r=0;r<5;r++) {
  auto start=std::chrono::steady_clock::now();
  for(int repeat=0;repeat<10;repeat++) {
   F x=0,y=0;
   for(int i=0;i<1000;i++){F xx=x*x-y*y; y=2*x*y+ci;x=xx+cr;}
   checksum+=x.template convert_to<double>();
  }
  if(r)std::cout<<",";
  std::cout<<std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
 }
 std::cout<<"],\"checksum\":"<<checksum<<"}\n";
}
int main(){run<397>(100);run<3386>(1000);}

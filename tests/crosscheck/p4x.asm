mov R1, 256
stream.add R0, [R1]+4, R0.w
mov R2, 10
stream.add R3, [R1]+8, R3.l
halt

k : forall s. forall t. s -> t -> s
k {s} {t} x y = x

k2 : forall b. forall a. a -> b -> a
k2 {b} {a} = k {a} {b}

kRealInt : Real -> Int -> Real
kRealInt = k {Real} {Int}

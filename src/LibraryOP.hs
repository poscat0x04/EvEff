{-# LANGUAGE TypeOperators, FlexibleContexts, Rank2Types, MagicHash #-}
module LibraryOP where

import Prelude
import EffEvScopedOP
import GHC.Prim
import GHC.Exts

------------
-- reader
data Reader a e ans = Reader { ask :: Op () a e ans }

{-# INLINE reader #-}
reader :: a -> Eff (Reader a :* e) ans -> Eff e ans
reader x action = handle
  Reader{ ask = function (\() -> return x) }
  action

------------
-- state
data State a e ans = State { get_ :: !(Op () a e ans)
                           , put_ :: !(Op a () e ans)  }

{-# INLINE get #-}
get :: (State a :? e)  => Eff e a
get = perform get_ ()

{-# INLINE put #-}
put :: (State a :? e)  => a -> Eff e ()
put i = (perform put_ i)

-- A monadic state handler
-- Note: can be done more efficient with parameterized control
mstate :: State a e (a -> Eff e ans)
mstate = State { get_ = operation (\() k -> return $ \s -> (k s  >>= \r -> r s ))
               , put_ = operation (\s  k -> return $ \_ -> (k () >>= \r -> r s))
               }

runNext :: (State Int :? e) => Int -> Eff e Int
runNext i = if (i == 0) then return i
             else put (i-1) >>= runCount

{-# NOINLINE runCount #-}
runCount :: (State Int :? e) => () -> Eff e Int
runCount () = get >>= runNext


count :: Int -> (Int, Int)
count n = erun $
            do let ret x = return (\s -> return (x,s))
               f <- handle mstate $
                      do x <- runCount ()
                         ret x
               f n

------------------------------------
-- Local state
-------------------------------------
lstate :: a -> Eff (State a :* e) ans -> Eff e ans
lstate init action
  = local init $ \l ->
    let h = State { get_ = function (\x -> localGet l x),
                    put_ = function (\x -> localSet l x) }
    in handle h action

lCount :: Int -> Int
lCount n = erun $ lstate n $
           do x <- runCount ()
              return x

main :: IO ()
main = do let x = lCount (10^6)
          print x


------------------------------------
-- Parameterized handler
-------------------------------------
newtype Parameter a = Parameter (Local a)

pNormal :: Parameter p -> (a -> p -> ((b,p) -> Eff e ans) -> Eff e ans) -> Op a b e ans
pNormal (Parameter p) op
  = operation (\x k -> do vx <- localGet p x
                          let kp (y,vy) = do{ localSet p vy; k y }
                          op x vx kp)

pTail :: Parameter p -> (a -> p -> Eff e (b,p)) -> Op a b e ans
pTail (Parameter p) op
 = function (\x -> do vx <- localGet p x
                      (y,vy) <- op x vx
                      localSet p vy
                      return y)

phandle :: (Parameter p -> h e ans) -> p -> Eff (h :* e) ans -> Eff e ans
phandle hcreate init action
  = local init $ \local ->
    let p = Parameter local
    in handle (hcreate p) action

pstate :: Parameter a -> State a e ans
pstate p = State { get_ = pTail p (\() v -> return (v,v)),
                   put_ = pTail p (\x v  -> return ((),x)) }

pCount :: Int -> Int
pCount n = erun $
           phandle pstate (n::Int) $
             do x <- runCount ()
                return x

------------
-- Write
------------

data Writer a e ans = Writer { tell_ :: !(Op a () e ans) }

{-# INLINE tell #-}
tell :: (Writer a :? e) => a -> Eff e ()
tell = perform tell_

writer :: (Monoid a) => a -> Eff (Writer a :* e) ans -> Eff e (a, ans)
{-# INLINE writer #-}
writer init action
  = local init $ \l ->
      let h = Writer { tell_ = function (\x -> do y <- localGet l x
                                                  localSet l (mappend y x)) }
      in do y <- handle h action
            x <- localGet l init
            return (x, y)

data Exn e ans = Exn { throwError_ :: forall a. Op String a e ans }

throwError :: In Exn e  => String -> Eff e a
throwError = perform throwError_

exn :: Exn e (Either String a)
exn = Exn (operation (\msg resume -> return $ Left msg))



---------------------------------------
-- non-tail
---------------------------------------

lstateNonTail :: a -> Eff (State a :* e) ans -> Eff e ans
lstateNonTail init action
  = local init $ \l ->
    let h = State { get_ = operation (\x k -> do y <- localGet l x; k y),
                    put_ = operation (\x k -> do localSet l x; k ()) }
    in handle h action

writerNonTail :: (Monoid a) => a -> Eff (Writer a :* e) ans -> Eff e (a, ans)
{-# INLINE writerNonTail #-}
writerNonTail init action
  = local init $ \l ->
      let h = Writer { tell_ = operation (\x k -> do y <- localGet l x
                                                     localSet l (mappend y x)
                                                     k ()) }
      in do y <- handle h action
            x <- localGet l init
            return (x, y)
